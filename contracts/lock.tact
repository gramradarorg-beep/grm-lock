// GRM Time-Lock — некастодиальное тайм-лок хранилище для jetton GRM (TON, TEP-74).
//
// СУТЬ: отправляешь GRM в контракт, указав срок (в секундах) в forward payload.
// До истечения срока вытащить нельзя НИКОМУ — у контракта НЕТ ни досрочного вывода,
// ни «админ-вывода». После срока монеты возвращаются ТОЛЬКО депозитору (или указанному
// получателю). UI (Gram Radar) лишь формирует транзакцию — логика живёт on-chain и не
// зависит от того, работает ли сайт.
//
// Модель хранения: одно хранилище, внутри map<lockId, Lock>. На разлоке запись
// удаляется → storage не растёт бесконечно (в памяти только активные локи).
//
// ⚠️ MVP. Перед крупными суммами — внешний аудит.

import "@stdlib/deploy";
import "./messages";

const MIN_LOCK_SEC: Int = 3600;            // минимум 1 час (отсечь мусор)
const MAX_LOCK_SEC: Int = 3155760000;      // максимум 100 лет
const FWD_TON: Int = ton("0.05");          // форвард на исходящий jetton-перевод
const KEEP_RESERVE: Int = ton("0.03");     // неснижаемый резерв на storage

// Комиссия разработчика на развитие проекта (НЕ может быть изменена — константа, без админ-вывода).
const DEV_ADDR: Address = address("UQBP5jM4bCh652IHVOGQ3biUWKbrXM1hvtLSzQU2x33nJD2A");
const PENALTY_PCT: Int = 10;               // 10% удерживается ТОЛЬКО при досрочном выводе
const DEV_FEE_TON: Int = ton("0.03");      // небольшой излишек TON с депозита → DEV_ADDR (расходы на пользователе)

// Storage-страховка: требуем TON-буфер пропорционально сроку лока, чтобы контракт пережил
// аренду хранилища весь срок (закрывает риск заморозки на длинных локах).
const SEC_PER_YEAR: Int = 31557600;
const STORAGE_BASE_TON: Int = ton("0.05");      // база (storage записи + запас)
const STORAGE_PER_YEAR_TON: Int = ton("0.02");  // буфер ренты на каждый год срока

// Опкоды в forward payload депозита.
const OP_LOCK: Int = 0;                    // новый лок: value = срок в секундах
const OP_TOPUP: Int = 1;                   // догрузка: value = lockId существующего лока

const MAX_TRANCHES: Int = 60;              // максимум равных частей вестинга (1 = обычный обрыв)

struct Lock {
    owner: Address;            // кому вернуть (= депозитор)
    amount: Int as coins;      // ИСХОДНАЯ сумма GRM (nano); выданное считается через claimed
    unlockAt: Int as uint64;   // финал — последний транш (unix)
    startAt: Int as uint64;    // старт вестинга (= момент лока)
    tranches: Int as uint16;   // число равных частей (1 = всё одним обрывом в unlockAt)
    claimed: Int as uint16;    // сколько частей уже выдано
}

contract GrmLock with Deployable {
    owner: Address;                 // только для разовой настройки jetton-кошелька
    jettonMaster: Address;          // GRM master
    myJettonWallet: Address;        // jetton-кошелёк ЭТОГО контракта (анти-спуфинг)
    walletSet: Bool = false;

    nextId: Int as uint64 = 0;
    totalLocked: Int as coins = 0;  // всего заперто GRM (для статистики)
    activeLocks: Int as uint32 = 0; // сколько активных записей
    locks: map<Int, Lock>;

    init(owner: Address, jettonMaster: Address) {
        self.owner = owner;
        self.jettonMaster = jettonMaster;
        self.myJettonWallet = owner;    // заглушка до SetJettonWallet
    }

    // Привязка собственного jetton-кошелька. Можно ПЕРЕзадать, пока НЕ создан ни один лок
    // (nextId == 0) — чтобы исправить опечатку при настройке без риска для средств.
    // После первого лока — заморожено навсегда (никакой власти над средствами у owner нет).
    receive(msg: SetJettonWallet) {
        require(sender() == self.owner, "only owner");
        require(self.nextId == 0, "vault already in use");
        self.myJettonWallet = msg.wallet;
        self.walletSet = true;
    }

    // === Депозит GRM ===
    // forward payload (inline): [Either-бит=0][op:uint32][value:uint64]
    //   op=OP_LOCK  → новый лок, value = срок в секундах
    //   op=OP_TOPUP → догрузка, value = lockId
    // Любой невалидный сценарий → GRM возвращаются отправителю (не запираем зря).
    receive(msg: JettonTransferNotification) {
        // КРИТИЧНО: принимаем только от собственного jetton-кошелька.
        require(sender() == self.myJettonWallet, "bad jetton wallet");
        if (msg.amount <= 0) { return; }

        let fp: Slice = msg.forwardPayload;
        if (fp.bits() < 1) { self.refund(msg.sender, msg.amount); return; }
        let isRef: Bool = fp.loadBool();
        let body: Slice = fp;
        if (isRef) {
            if (fp.refs() < 1) { self.refund(msg.sender, msg.amount); return; }
            body = fp.loadRef().beginParse();
        }
        // нужен op(32) + value(64)
        if (body.bits() < 96) { self.refund(msg.sender, msg.amount); return; }
        let op: Int = body.loadUint(32);
        let val: Int = body.loadUint(64);

        // --- ДОГРУЗКА существующего лока ---
        if (op == OP_TOPUP) {
            let opt: Lock? = self.locks.get(val);
            if (opt == null) { self.refund(msg.sender, msg.amount); return; }
            let lock: Lock = opt!!;
            // догрузка только ПРОСТЫХ (нетраншевых) и ещё не созревших локов —
            // иначе расчёт уже выданных долей поехал бы.
            if (lock.tranches != 1 || now() >= lock.unlockAt) { self.refund(msg.sender, msg.amount); return; }
            lock.amount += msg.amount;
            self.locks.set(val, lock);          // срок (unlockAt) НЕ меняется
            self.totalLocked += msg.amount;
            self.payDevFee();
            return;
        }

        // --- НОВЫЙ ЛОК ---
        let lockSeconds: Int = val;
        if (lockSeconds < MIN_LOCK_SEC || lockSeconds > MAX_LOCK_SEC) {
            self.refund(msg.sender, msg.amount);
            return;
        }

        // опционально: число траншей вестинга (uint16 после op+value). По умолчанию 1 (обрыв).
        let tranches: Int = 1;
        if (body.bits() >= 16) {
            tranches = body.loadUint(16);
            if (tranches < 1 || tranches > MAX_TRANCHES) { self.refund(msg.sender, msg.amount); return; }
        }

        // STORAGE-СТРАХОВКА: приложенного TON должно хватить на буфер ренты под весь срок.
        let need: Int = DEV_FEE_TON + STORAGE_BASE_TON + lockSeconds * STORAGE_PER_YEAR_TON / SEC_PER_YEAR;
        if (context().value < need) {
            self.refund(msg.sender, msg.amount);
            return;
        }

        let id: Int = self.nextId;
        self.nextId += 1;
        self.locks.set(id, Lock{
            owner: msg.sender,
            amount: msg.amount,
            unlockAt: now() + lockSeconds,
            startAt: now(),
            tranches: tranches,
            claimed: 0
        });
        self.totalLocked += msg.amount;
        self.activeLocks += 1;
        self.payDevFee();   // буфер ренты остаётся в контракте, наружу уходит только DEV_FEE_TON
    }

    // === Разлок (permissionless) ===
    // Выдаёт все СОЗРЕВШИЕ, но ещё не выданные транши владельцу записи. Для обычного лока
    // (tranches=1) это «всё после срока». Для вестинга — частями, по мере созревания.
    // Вызвать может кто угодно; GRM уходят ТОЛЬКО владельцу.
    receive(msg: Unlock) {
        let opt: Lock? = self.locks.get(msg.lockId);
        require(opt != null, "no such lock");
        let lock: Lock = opt!!;
        require(myBalance() >= FWD_TON + KEEP_RESERVE, "low TON, attach gas");

        // сколько траншей созрело к настоящему моменту [0..tranches]
        let dur: Int = lock.unlockAt - lock.startAt;          // > 0 (lockSeconds >= 3600)
        let elapsed: Int = now() - lock.startAt;
        let matured: Int = 0;
        if (elapsed >= dur) { matured = lock.tranches; }
        else if (elapsed > 0) { matured = elapsed * lock.tranches / dur; }
        require(matured > lock.claimed, "nothing matured yet");

        // выдаём накопленную долю минус уже выданное; на финале — весь остаток (без пыли)
        let sentBefore: Int = lock.amount * lock.claimed / lock.tranches;
        let cumNow: Int = lock.amount;
        if (matured < lock.tranches) { cumNow = lock.amount * matured / lock.tranches; }
        let toSend: Int = cumNow - sentBefore;

        self.totalLocked -= toSend;
        if (matured >= lock.tranches) {
            self.locks.set(msg.lockId, null);                 // всё выдано — удаляем
            if (self.activeLocks > 0) { self.activeLocks -= 1; }
        } else {
            lock.claimed = matured;
            self.locks.set(msg.lockId, lock);                 // обновляем прогресс
        }
        self.sendJetton(lock.owner, toSend);                  // отправка после записи состояния
    }

    // === Экстренный (досрочный) вывод ===
    // Только владелец. Забирает ВЕСЬ ещё не выданный остаток: 90% владельцу, 10% — разработчику.
    receive(msg: EmergencyUnlock) {
        let opt: Lock? = self.locks.get(msg.lockId);
        require(opt != null, "no such lock");
        let lock: Lock = opt!!;
        require(sender() == lock.owner, "only lock owner");
        require(myBalance() >= FWD_TON * 2 + KEEP_RESERVE, "low TON, attach gas");

        let sentBefore: Int = lock.amount * lock.claimed / lock.tranches;
        let remaining: Int = lock.amount - sentBefore;        // ещё не выданное

        // удаляем запись ДО отправок (анти-реентранси)
        self.locks.set(msg.lockId, null);
        self.totalLocked -= remaining;
        if (self.activeLocks > 0) { self.activeLocks -= 1; }

        let penalty: Int = remaining * PENALTY_PCT / 100;     // 10% от остатка
        let payout: Int = remaining - penalty;                // 90% (+ остаток округления — владельцу)
        self.sendJetton(lock.owner, payout);
        if (penalty > 0) {
            self.sendJetton(DEV_ADDR, penalty);
        }
    }

    // приём пополнений TON (буфер газа) и глушение служебных сообщений
    receive() {}
    receive(msg: Slice) {}

    // --- helpers ---
    fun sendJetton(to: Address, amount: Int) {
        if (amount <= 0) { return; }
        send(SendParameters{
            to: self.myJettonWallet,
            value: FWD_TON,
            mode: SendPayGasSeparately,
            body: JettonTransfer{
                queryId: 0,
                amount: amount,
                destination: to,
                responseDestination: to,
                customPayload: null,
                forwardTonAmount: 1,                 // 1 nano, чтобы пришёл notification
                forwardPayload: beginCell().storeUint(0, 1).asSlice()  // ≥1 бит (Either-флаг)
            }.toCell()
        });
    }

    fun refund(to: Address, amount: Int) {
        self.sendJetton(to, amount);
    }

    // Небольшой излишек TON (расходы на пользователе) → кошелёк разработчика. Неблокирующе.
    fun payDevFee() {
        if (myBalance() >= DEV_FEE_TON + KEEP_RESERVE) {
            send(SendParameters{ to: DEV_ADDR, value: DEV_FEE_TON, mode: SendPayGasSeparately, bounce: false });
        }
    }

    // --- геттеры ---
    get fun lockInfo(id: Int): LockView {
        let opt: Lock? = self.locks.get(id);
        if (opt == null) {
            return LockView{ exists: false, owner: myAddress(), amount: 0, unlockAt: 0, createdAt: 0, tranches: 0, claimed: 0 };
        }
        let l: Lock = opt!!;
        return LockView{
            exists: true, owner: l.owner, amount: l.amount,
            unlockAt: l.unlockAt, createdAt: l.startAt,
            tranches: l.tranches, claimed: l.claimed
        };
    }

    get fun stats(): map<Int, Int> {
        let m: map<Int, Int> = emptyMap();
        m.set(0, self.nextId);          // всего создано локов
        m.set(1, self.activeLocks);     // активных сейчас
        m.set(2, self.totalLocked);     // всего заперто GRM (nano)
        return m;
    }

    get fun jettonWallet(): Address {
        return self.myJettonWallet;
    }
}
