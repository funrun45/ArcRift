"""Reference generator for the Rift S display mode (EDID) that ArcRift applies during a session.

Timings come from a published Rift S capture (https://pastebin.com/8rPrTETP, linked from
https://github.com/OpenHMD/OpenHMD/issues/225#issuecomment-651707192). Only the serial descriptor and the
checksum change: the session script writes the user's own headset serial (from Setup), which Meta uses to
pair the display with the headset. test-ovr-d3d11.ps1 does the same thing at the start of every session;
this script is kept for reference. The result is an OS override only; never flash it to hardware.

Usage: python make_edid.py YOURSERIAL
"""
import sys
from pathlib import Path

TEMPLATE = bytes.fromhex(
    '00ffffffffffff003ed2120000000000011d0104a50000000e000000000000000000000000000101010101010101'
    '010101010101010145dfa0385100eea5d20cf10c000000000010000000ff0030303030303030303030303030000000'
    'fc005269667420530a20202020202000000010000000000000000000000000000000e6')
serial = sys.argv[1].encode('ascii') if len(sys.argv) > 1 else b''
if not serial.isalnum():
    sys.exit('Usage: python make_edid.py YOURSERIAL')
data = bytearray(TEMPLATE)
text = serial[-13:] if len(serial) >= 13 else serial + b'\n' + b' ' * (12 - len(serial))
data[77:90] = text
data[127] = (-sum(data[:127])) & 255
d = data[54:72]
clock = int.from_bytes(d[:2], 'little') * 10000
width, hblank = d[2] + ((d[4] >> 4) << 8), d[3] + ((d[4] & 15) << 8)
height, vblank = d[5] + ((d[7] >> 4) << 8), d[6] + ((d[7] & 15) << 8)
hz = clock / ((width + hblank) * (height + vblank))
assert (width, height) == (1440, 2560) and 79.99 < hz < 80.01 and sum(data) % 256 == 0
out = Path(__file__).with_name('rift-s-native-test.edid')
out.write_bytes(data)
print(f'{width}x{height} {hz:.5f} Hz, clock={clock}, checksummed -> {out}')
