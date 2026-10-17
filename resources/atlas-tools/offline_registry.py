"""Edit extracted Windows hives through libhivex, never the Linux host registry."""
import struct
import hivex


class Hive:
    def __init__(self, path):
        self.handle = hivex.Hivex(str(path), write=True)

    def node(self, path, create=False):
        node = self.handle.root()
        for part in path.split('\\'):
            if not part:
                continue
            child = self.handle.node_get_child(node, part)
            if not child and create:
                child = self.handle.node_add_child(node, part)
            if not child:
                return None
            node = child
        return node

    def get(self, path, name):
        node = self.node(path)
        # Some Python hivex bindings raise RuntimeError("Success") for a missing value.
        value = next((v for v in self.handle.node_values(node)
                      if self.handle.value_key(v).casefold() == name.casefold()), None) if node else None
        if not value:
            return None
        kind, data = self.handle.value_value(value)
        return kind, data

    def set(self, path, name, value, kind=4):
        if kind == 4:
            value = struct.pack('<I', value)
        elif kind in (1, 2):
            value = (value + '\0').encode('utf-16-le')
        self.handle.node_set_value(self.node(path, create=True), {'key': name, 't': kind, 'value': value})

    def commit(self):
        self.handle.commit(None)


# Same preparation values as AME 0.8.4 RunPlaybook(ISO=true), DefenderToggled path.
DEFENDER_PREPARATION = [
    ('Policies\\Microsoft\\Windows Defender\\Real-Time Protection', 'DisableRealtimeMonitoring', 1),
    ('Microsoft\\Windows Defender\\Real-Time Protection', 'DisableRealtimeMonitoring', 1),
    ('Microsoft\\Windows Defender\\Real-Time Protection', 'DisableAsyncScanOnOpen', 1),
    ('Microsoft\\Windows Defender\\SpyNet', 'SpyNetReporting', 0),
    ('Microsoft\\Windows Defender\\SpyNet', 'SubmitSamplesConsent', 0),
    ('Microsoft\\Windows Defender\\Features', 'TamperProtection', 4),
]


def selected_control_sets(system):
    """Resolve offline boot selection without inventing nonexistent control sets."""
    found = set()
    for name in ('Default', 'Current'):
        entry = system.get('Select', name)
        if entry is None:
            continue
        kind, data = entry
        if kind != 4 or len(data) != 4:
            raise ValueError(f'Invalid SYSTEM Select {name}')
        number = struct.unpack('<I', data)[0]
        path = f'ControlSet{number:03d}'
        if not 1 <= number <= 999 or system.node(path) is None:
            raise ValueError(f'SYSTEM Select {name} references an invalid control set')
        found.add(path)
    if not found:
        if system.node('ControlSet001') is None:
            raise ValueError('SYSTEM has no selected or default control set')
        found.add('ControlSet001')
    return sorted(found)


def prepare_install(software, system):
    software, system = Hive(software), Hive(system)
    control_sets = selected_control_sets(system)
    backup = []
    for path, name, value in DEFENDER_PREPARATION:
        original = software.get(path, name)
        backup.append({'path': path, 'name': name, 'prepared': value,
                       'originalType': original[0] if original else None,
                       'originalBytes': list(original[1]) if original else None})
        software.set(path, name, value)
    for control_set in control_sets:
        service = f'{control_set}\\Services\\ameoobe'
        for name, value in {'DisplayName': 'AME OOBE', 'ObjectName': 'LocalSystem'}.items():
            system.set(service, name, value, 1)
        # InterLink's service verifies that its peer has the SAME executable path.
        # The pinned shim launches AME.Client.exe, so the service must use it too.
        system.set(service, 'ImagePath', '"%ProgramData%\\AME\\OOBE\\AME.Client.exe" --service', 2)
        for name, value in {'ErrorControl': 0, 'Start': 2, 'Type': 16}.items():
            system.set(service, name, value)
        # Suppress automatic guest disk encryption, matching AME's generated unattend.
        system.set(f'{control_set}\\Control\\BitLocker', 'PreventDeviceEncryption', 1)
    software.commit()
    system.commit()
    return backup


def prepare_boot(system):
    system = Hive(system)
    for name in ['BypassRAMCheck', 'BypassSecureBootCheck', 'BypassCPUCheck', 'BypassTPMCheck']:
        system.set('Setup\\LabConfig', name, 1)
    system.commit()
