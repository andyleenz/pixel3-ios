#!/usr/bin/env python3
"""Write a SystemConfiguration preferences.plist with one network set and a
Wi-Fi service on en0 (DHCP, IPv6 automatic), for pushing into the iOS root:

  tools/configd-prefs.py OUT
  tools/phonetest.sh ... --push OUT:/private/var/preferences/SystemConfiguration/preferences.plist

configd makes this file itself on a first boot. On the phone's migrated root
it holds only __VERSION__, so en0 (named by InterfaceNamer, listed in
NetworkInterfaces.plist) has no service: IPConfiguration never brings it up
or asks for an address. The set and service ids are fixed, so pushing it
again changes nothing.
"""
import plistlib
import sys

SET = '5B4D7C1E-3F2A-4E8B-9C61-0A1B2C3D4E5F'
SVC = '8E2F6A3B-1C4D-4F5E-A6B7-C8D9E0F1A2B3'

prefs = {
    'CurrentSet': f'/Sets/{SET}',
    'NetworkServices': {
        SVC: {
            'DNS': {},
            'IPv4': {'ConfigMethod': 'DHCP'},
            'IPv6': {'ConfigMethod': 'Automatic'},
            'Interface': {'DeviceName': 'en0', 'Hardware': 'AirPort', 'Type': 'Ethernet', 'UserDefinedName': 'Wi-Fi'},
            'Proxies': {'ExceptionsList': ['*.local', '169.254/16'], 'FTPPassive': 1},
            'UserDefinedName': 'Wi-Fi',
        },
    },
    'Sets': {
        SET: {
            'Network': {
                'Global': {'IPv4': {'ServiceOrder': [SVC]}},
                'Service': {SVC: {'__LINK__': f'/NetworkServices/{SVC}'}},
            },
            'UserDefinedName': 'Automatic',
        },
    },
    'System': {'Network': {'HostNames': {'LocalHostName': 'iPhone'}}, 'System': {'ComputerName': 'iPhone'}},
    '__VERSION__': 20191120,
}

with open(sys.argv[1], 'wb') as f:
    plistlib.dump(prefs, f, fmt=plistlib.FMT_XML)
