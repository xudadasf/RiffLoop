import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

spec = importlib.util.spec_from_file_location('renew_device', Path(__file__).with_name('renew-device.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Device:
    def __init__(self, serial, transport):
        self.serial, self.connection_type = serial, transport

    def matches_udid(self, udid):
        return self.serial == udid


class TransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_binary_app_metadata_does_not_break_snapshot_json(self):
        client=AsyncMock()
        client.all_values={'DeviceClass':'iPad'}
        client.__aenter__.return_value=client
        service=AsyncMock();service.__aenter__.return_value=service
        service.get_apps.return_value={
            'com.riffloop.prototype.test':{'CFBundleShortVersionString':'0.25.99','CFBundleVersion':'123',
                'SignerIdentity':'Apple Development: test@example.com (TEAM)', 'ApplicationSINF':b'\xff\x00'},
            'com.example.other':{'Receipt':b'\xff'}}
        with patch.object(module.usbmux,'list_devices',AsyncMock(return_value=[Device('target','USB')])), \
             patch.object(module,'create_using_usbmux',AsyncMock(return_value=client)), \
             patch.object(module,'InstallationProxyService',return_value=service):
            result=await module.snapshot('USB','target')
        decoded=json.loads(json.dumps(result))
        self.assertEqual(list(decoded['Apps']),['com.riffloop.prototype.test'])
        self.assertEqual(decoded['Apps']['com.riffloop.prototype.test']['CFBundleVersion'],'123')
        self.assertNotIn('ApplicationSINF',decoded['Apps']['com.riffloop.prototype.test'])

    async def test_same_ipad_on_two_transports_uses_requested_transport(self):
        client = AsyncMock()
        client.all_values = {'DeviceClass': 'iPad'}
        client.__aenter__.return_value = client
        service = AsyncMock()
        service.__aenter__.return_value = service
        service.get_apps.return_value = {'com.riffloop.prototype.test': {}}
        devices = [Device('target', 'USB'), Device('target', 'Network')]
        with patch.object(module.usbmux, 'list_devices', AsyncMock(return_value=devices)), \
             patch.object(module, 'create_using_usbmux', AsyncMock(return_value=client)) as connect, \
             patch.object(module, 'InstallationProxyService', return_value=service):
            for transport in ('Network', 'USB'):
                result = await module.snapshot(transport, 'target')
                self.assertEqual(result['Identifier'], 'target')
                connect.assert_awaited_with(serial='target', connection_type=transport, autopair=False)

    async def test_wifi_setup_enables_once_and_verifies_on_trusted_usb(self):
        for enabled in (False,True):
            with self.subTest(enabled=enabled):
                client=AsyncMock();client.all_values={'DeviceClass':'iPad'};client.__aenter__.return_value=client
                client.get_enable_wifi_connections.side_effect=[enabled,True]
                service=AsyncMock();service.__aenter__.return_value=service
                service.get_apps.return_value={'com.riffloop.prototype.test':{'CFBundleVersion':'123'}}
                with patch.object(module.usbmux,'list_devices',AsyncMock(return_value=[Device('target','USB')])), \
                     patch.object(module,'create_using_usbmux',AsyncMock(return_value=client)) as connect, \
                     patch.object(module,'InstallationProxyService',return_value=service):
                    result=await module.snapshot('USB','target',setup_wifi=True)
                self.assertTrue(result['WifiEnabled'])
                connect.assert_awaited_with(serial='target',connection_type='USB',autopair=False)
                self.assertEqual(client.set_enable_wifi_connections.await_count,0 if enabled else 1)

    async def test_wifi_setup_refuses_network_and_unrelated_device(self):
        with self.assertRaisesRegex(ValueError,'USB'):
            await module.snapshot('Network','target',setup_wifi=True)
        client=AsyncMock();client.all_values={'DeviceClass':'iPad'};client.__aenter__.return_value=client
        service=AsyncMock();service.__aenter__.return_value=service
        service.get_apps.return_value={'com.other':{}}
        with patch.object(module.usbmux,'list_devices',AsyncMock(return_value=[Device('target','USB')])), \
             patch.object(module,'create_using_usbmux',AsyncMock(return_value=client)), \
             patch.object(module,'InstallationProxyService',return_value=service):
            with self.assertRaisesRegex(RuntimeError,'one installed RiffLoop'):
                await module.snapshot('USB','target',setup_wifi=True)
        client.set_enable_wifi_connections.assert_not_awaited()

    async def test_delayed_network_discovery_retries_without_switching_transport(self):
        with patch.object(module.usbmux,'list_devices',AsyncMock(side_effect=[
                [Device('target','USB')],[Device('target','USB'),Device('target','Network')]])), \
             patch.object(module.asyncio,'sleep',AsyncMock()):
            device=await module.find_device('Network','target',wait_seconds=5)
        self.assertEqual(device.connection_type,'Network')

    async def test_fallback_refuses_different_usb_device(self):
        with patch.object(module.usbmux, 'list_devices', AsyncMock(return_value=[Device('other', 'USB')])):
            with self.assertRaisesRegex(RuntimeError, 'found 0'):
                await module.snapshot('USB', 'target')

    async def test_ambiguous_devices_are_rejected(self):
        devices = [Device('one', 'Network'), Device('two', 'Network')]
        with patch.object(module.usbmux, 'list_devices', AsyncMock(return_value=devices)):
            with self.assertRaisesRegex(RuntimeError, 'found 2'):
                await module.snapshot('Network', '')


if __name__ == '__main__':
    unittest.main()
