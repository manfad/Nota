import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey, registered through Carbon's `RegisterEventHotKey`.
///
/// Carbon is used deliberately: it is the only way to get a global shortcut
/// without asking for Accessibility permission, which an event tap would
/// require. The API is old but it is not deprecated and has no replacement.
final class GlobalHotKey {
    /// A key combination, stored as a virtual key code plus Cocoa modifiers.
    struct Shortcut: Equatable {
        var keyCode: UInt32
        /// `NSEvent.ModifierFlags` raw value, device-independent flags only.
        var modifiers: UInt

        /// ⌥Space.
        static let optionSpace = Shortcut(
            keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags.option.rawValue
        )

        var flags: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiers)
        }

        /// Something like "⌥Space" for the recorder field.
        var displayName: String {
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            return text + KeyCodeNames.name(for: keyCode)
        }
    }

    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var callback: (() -> Void)?

    /// The last registration failed — almost always because something else
    /// already owns the combination.
    private(set) var registrationFailed = false

    private static let signature: OSType = 0x4A4F5421  // 'JOT!'

    init() {}

    deinit { unregister() }

    @discardableResult
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        unregister()
        callback = action
        registrationFailed = false

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context else { return noErr }
                var identifier = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard identifier.signature == GlobalHotKey.signature else { return noErr }
                Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().fire()
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard installed == noErr else {
            registrationFailed = true
            return false
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            Self.carbonModifiers(from: shortcut.flags),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard status == noErr, hotKey != nil else {
            registrationFailed = true
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func fire() {
        callback?()
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

/// Readable names for the handful of key codes that have no printable glyph.
enum KeyCodeNames {
    private static let named: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    static func name(for keyCode: UInt32) -> String {
        named[keyCode] ?? "Key \(keyCode)"
    }
}
