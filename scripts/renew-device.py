"""Read the target through an explicitly selected usbmux transport; never pair silently."""
import argparse
import asyncio
import json
import sys

from pymobiledevice3 import usbmux
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.installation_proxy import InstallationProxyService


APP_FIELDS = ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion', 'SignerIdentity')


def renewal_apps(apps):
    """Only export renewal metadata; app receipts/SINF can contain binary plists."""
    result = {}
    for bundle, app in apps.items():
        if bundle != 'com.riffloop.prototype' and not bundle.startswith('com.riffloop.prototype.'):
            continue
        result[bundle] = {}
        for field in APP_FIELDS:
            value = app.get(field)
            if value is not None:
                if type(value) not in (str, int):
                    raise ValueError(f'RiffLoop {field} is not text')
                result[bundle][field] = str(value)
    return result


async def find_device(transport, udid, wait_seconds=0):
    deadline = asyncio.get_running_loop().time() + wait_seconds
    while True:
        devices = await usbmux.list_devices()
        candidates = {d.serial: d for d in devices
                      if d.connection_type == transport and (not udid or d.matches_udid(udid))}
        if len(candidates) == 1:
            return next(iter(candidates.values()))
        if len(candidates) > 1 or asyncio.get_running_loop().time() >= deadline:
            raise RuntimeError(f'{transport}: expected one device, found {len(candidates)}')
        await asyncio.sleep(min(1, max(0, deadline - asyncio.get_running_loop().time())))


async def snapshot(transport, udid, wait_seconds=0, setup_wifi=False):
    if setup_wifi and transport != 'USB':
        raise ValueError('Wireless setup requires a trusted USB connection')
    device = await find_device(transport, udid, wait_seconds)
    async with await create_using_usbmux(serial=device.serial, connection_type=transport,
                                       autopair=False) as client:
        if client.all_values.get('DeviceClass') != 'iPad':
            raise RuntimeError('Selected device is not an iPad')
        async with InstallationProxyService(client) as service:
            apps = await service.get_apps()
        result = {'Identifier': device.serial, 'Apps': renewal_apps(apps), 'Transport': transport}
        if setup_wifi:
            if len(result['Apps']) != 1:
                raise RuntimeError('Wireless setup requires exactly one installed RiffLoop')
            if not await client.get_enable_wifi_connections():
                await client.set_enable_wifi_connections(True)
            result['WifiEnabled'] = bool(await client.get_enable_wifi_connections())
            if not result['WifiEnabled']:
                raise RuntimeError('iPad did not confirm Wi-Fi connections enabled')
        return result


async def diagnose():
    from pymobiledevice3.bonjour import browse_mobdev2
    devices = await usbmux.list_devices()
    services = await browse_mobdev2(timeout=5)
    return {'USB': len({d.serial for d in devices if d.connection_type == 'USB'}),
            'Network': len({d.serial for d in devices if d.connection_type == 'Network'}),
            'BonjourAdvertisements': len(services)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--transport', choices=['Network', 'USB'])
    parser.add_argument('--udid', default='')
    parser.add_argument('--wait-seconds', type=int, choices=range(0,61), default=0, metavar='0-60')
    parser.add_argument('--setup-wifi', action='store_true')
    parser.add_argument('--diagnose', action='store_true')
    args = parser.parse_args()
    if not args.diagnose and not args.transport:
        parser.error('--transport is required unless --diagnose is used')
    try:
        action = diagnose() if args.diagnose else snapshot(args.transport, args.udid, args.wait_seconds, args.setup_wifi)
        result = asyncio.run(asyncio.wait_for(action, timeout=args.wait_seconds+25))
        print(json.dumps(result))
    except Exception as exc:
        print(f'Device connection failed: {type(exc).__name__}: {exc}', file=sys.stderr)
        sys.exit(1)
