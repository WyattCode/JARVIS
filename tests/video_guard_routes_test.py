"""Exercise the actual HTTP bridge with a fake worker; never generates media."""
import asyncio
import importlib.util
import json
from pathlib import Path
import unittest
import threading
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('brain_routes', Path(__file__).resolve().parents[1] / 'deploy/jarvis/remote_brain.py')
brain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(brain)


class RoutesTests(unittest.IsolatedAsyncioTestCase):
    async def test_disconnect_during_preparation_does_not_submit_video(self):
        started = asyncio.Event()
        release = threading.Event()
        loop = asyncio.get_running_loop()
        def prepare(prompt):
            loop.call_soon_threadsafe(started.set)
            release.wait(3)
            return 'compact'
        with patch.object(brain, 'prepare_video_prompt', side_effect=prepare):
            reader, writer = await asyncio.open_connection('127.0.0.1', self.bridge.sockets[0].getsockname()[1])
            payload = json.dumps({'prompt': 'long'}).encode()
            writer.write(f'POST /v1/videos HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n'.encode() + payload)
            await writer.drain()
            try:
                await asyncio.wait_for(started.wait(), 2)
                writer.close()
                await writer.wait_closed()
                await asyncio.sleep(.05)
                release.set()
                await asyncio.sleep(.1)
                self.assertEqual(self.forwarded, [])
                self.assertEqual(self.connections, 0)
            finally:
                release.set()
                writer.close()

    async def asyncSetUp(self):
        self.forwarded = []
        self.connections = 0

        async def worker(reader, writer):
            self.connections += 1
            try:
                head = await reader.readuntil(b'\r\n\r\n')
            except asyncio.IncompleteReadError:
                writer.close()
                await writer.wait_closed()
                return
            length = next(int(line.split(b':', 1)[1]) for line in head.split(b'\r\n') if line.lower().startswith(b'content-length:'))
            self.forwarded.append(json.loads(await reader.readexactly(length)))
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}')
            await writer.drain()
            writer.close()
            await writer.wait_closed()

        self.worker = await asyncio.start_server(worker, '127.0.0.1', 0)
        port = self.worker.sockets[0].getsockname()[1]
        bridge = brain.Bridge({'base_url': 'http://127.0.0.1:1/v1', 'video_worker_port': port, 'video_backend_port': port}, port)
        self.router = bridge
        self.worker_port = port
        self.bridge = await asyncio.start_server(bridge.client, '127.0.0.1', 0)

    async def asyncTearDown(self):
        for server in (self.bridge, self.worker):
            server.close()
            await server.wait_closed()

    async def request(self, path, body, content_type='application/json'):
        reader, writer = await asyncio.open_connection('127.0.0.1', self.bridge.sockets[0].getsockname()[1])
        payload = json.dumps(body).encode()
        writer.write(f'POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: {content_type}\r\nContent-Length: {len(payload)}\r\n\r\n'.encode() + payload)
        await writer.drain()
        response = await asyncio.wait_for(reader.read(), 5)
        writer.close()
        await writer.wait_closed()
        return response

    async def test_json_and_mcp_forward_only_prepared_prompt(self):
        with patch.object(brain, 'prepare_video_prompt', return_value='compact') as prepare:
            response = await self.request('/v1/videos', {'prompt': 'long', 'seed': 42}, 'Application/JSON; charset=utf-8')
            self.assertIn(b'200 OK', response)
            self.assertEqual(self.forwarded[-1], {'prompt': 'compact', 'seed': 42})
            response = await self.request('/mcp', {'jsonrpc': '2.0', 'id': 7, 'method': 'tools/call', 'params': {'name': 'generate_video', 'arguments': {'prompt': 'long', 'seconds': 5}}})
            self.assertIn(b'200 OK', response)
            self.assertEqual(self.forwarded[-1]['params']['arguments'], {'prompt': 'compact', 'seconds': 5})
            self.assertEqual(prepare.call_count, 2)

    async def test_guard_failure_never_reaches_worker_and_mcp_returns_tool_error(self):
        with patch.object(brain, 'prepare_video_prompt', side_effect=ValueError('guard failed')):
            self.assertIn(b'400', await self.request('/v1/videos', {'prompt': 'long'}))
            response = await self.request('/mcp', {'jsonrpc': '2.0', 'id': 7, 'method': 'tools/call', 'params': {'name': 'generate_video', 'arguments': {'prompt': 'long'}}})
            body = json.loads(response.split(b'\r\n\r\n', 1)[1])
            self.assertTrue(body['result']['isError'])
            self.assertEqual(body['id'], 7)
            self.assertEqual(self.forwarded, [])

    async def test_invalid_body_and_unsupported_format_fail_before_forwarding(self):
        self.assertIn(b'400', await self.request('/v1/videos', []))
        self.assertIn(b'400', await self.request('/v1/videos', {'prompt': 'long'}, 'multipart/form-data; boundary=test'))
        self.assertEqual(self.forwarded, [])

    async def test_cancel_locates_owner_with_read_only_probe_then_forwards_cancel(self):
        probes = []
        async def probe(port, value, **kwargs):
            probes.append(value)
            if port != self.worker_port:
                return {'result': {'isError': True, 'content': []}}
            return {'jsonrpc': '2.0', 'id': 8, 'result': {'isError': False, 'content': [{'type':'text','text':json.dumps({'id':value['params']['arguments']['id'],'status':'queued'})}]}}
        self.router.local_rpc = probe
        self.router.config['video_backend_port'] = 1
        self.router.config['image_worker_port'] = self.worker_port
        for job in ('video_123', 'img_123', 'image_123'):
            response = await self.request('/mcp', {'jsonrpc': '2.0', 'id': 8, 'method': 'tools/call', 'params': {'name': 'cancel_job', 'arguments': {'id': job}}})
            self.assertIn(b'200 OK', response)
            self.assertEqual(probes[-1]['params'], {'name': 'get_job', 'arguments': {'id': job, 'wait_s': 0}})
            self.assertEqual(self.forwarded[-1]['params'], {'name': 'cancel_job', 'arguments': {'id': job}})
