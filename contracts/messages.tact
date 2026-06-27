// TEP-74 jetton сообщения + сообщения управления тайм-локом GRM.

// --- TEP-74 ---
message(0x7362d09c) JettonTransferNotification {
    queryId: Int as uint64;
    amount: Int as coins;            // сколько GRM пришло (nano)
    sender: Address;                 // исходный владелец = депозитор
    forwardPayload: Slice as remaining;
}

message(0x0f8a7ea5) JettonTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    destination: Address;
    responseDestination: Address;
    customPayload: Cell?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

// --- Управление локом ---
// Депозитор один раз задаёт jetton-кошелёк контракта (анти-спуфинг).
message SetJettonWallet {
    wallet: Address;
}

// Разлок конкретной записи (permissionless — после срока может вызвать кто угодно,
// GRM уйдут ТОЛЬКО записанному владельцу).
message Unlock {
    lockId: Int as uint64;
}

// Экстренный (досрочный) вывод ДО срока — только владелец записи.
// Возвращается 90% GRM владельцу, 10% — комиссия разработчика на развитие проекта.
message EmergencyUnlock {
    lockId: Int as uint64;
}

// Вьюха геттера одной записи лока.
struct LockView {
    exists: Bool;
    owner: Address;
    amount: Int;        // исходная сумма GRM (nano)
    unlockAt: Int;      // финал (последний транш)
    createdAt: Int;     // = старт вестинга
    tranches: Int;      // число равных частей (1 = обычный обрыв)
    claimed: Int;       // сколько частей уже выдано
    hardLock: Bool;     // жёсткий лок (досрочный вывод запрещён)
}
