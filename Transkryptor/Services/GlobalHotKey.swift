import Carbon.HIToolbox
import Foundation

/// Globalny skrót klawiszowy (działa, gdy aplikacja jest w tle — np. gdy oglądasz kurs
/// w Safari). Użyty Carbon RegisterEventHotKey nie wymaga dodatkowych uprawnień.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    /// keyCode: kod klawisza (np. kVK_ANSI_S). modifiers: cmdKey, optionKey, ... (Carbon).
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        GlobalHotKey.handlers[id] = handler
        GlobalHotKey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x54524B59) /* 'TRKY' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            GlobalHotKey.handlers[id] = nil
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        GlobalHotKey.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let captured = hkID.id
            DispatchQueue.main.async { GlobalHotKey.handlers[captured]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
