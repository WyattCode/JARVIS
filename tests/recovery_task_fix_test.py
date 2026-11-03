import asyncio
import copy
import json
import unittest

import model_status_test as fixtures

brain = fixtures.brain


def job_reply(job_id, status='failed', error='original decode failure'):
    summary = {'id': job_id, 'status': status, 'error': error}
    return {'jsonrpc': '2.0', 'id': 17, 'result': {'isError': status == 'failed',
            'content': [{'type': 'text', 'text': json.dumps(summary)}]}}


class JobOwnershipSummary(unittest.TestCase):
    def test_existing_job_is_recognized_independent_of_completion_success(self):
        for state in ('queued', 'in_progress', 'completed', 'failed', 'cancelled'):
            result = job_reply('transcription_123', state)
            result['result']['content'].insert(0, {'type': 'text', 'text': 'recognized speech before summary'})
            self.assertEqual(brain.Bridge.rpc_job_summary(result, 'transcription_123')['status'], state)

    def test_unrelated_errors_and_malformed_success_are_not_ownership(self):
        cases = [None, [], {}, {'error': {'message': 'offline'}},
                 {'result': {'isError': False, 'content': []}},
                 {'result': {'isError': True, 'content': [{'type': 'text', 'text': 'no such job: transcription_123'}]}},
                 job_reply('transcription_other'), job_reply('transcription_123', 'unavailable'),
                 {'result': {'content': [{'type': 'text', 'text': '[]'}]}},
                 {'result': {'content': [{'type': 'text', 'text': '{"id":"transcription_123","error":"offline"}'}]}}]
        for reply in cases:
            with self.subTest(reply=reply):
                self.assertIsNone(brain.Bridge.rpc_job_summary(reply, 'transcription_123'))


class ReleaseScope(unittest.IsolatedAsyncioTestCase):
    async def test_split_topologies_refuse_without_querying_or_unloading(self):
        base = {k: v for k, v in fixtures.CFG.items() if not k.endswith('_port')}
        for field in ('video_worker_port', 'image_worker_port', 'speech_backend_port', 'transcription_backend_port'):
            with self.subTest(field=field):
                bridge = brain.Bridge({**base, field: 18100})
                async def forbidden(*args, **kwargs):
                    self.fail('release refusal must not call a service')
                bridge.fetch_json = bridge.local_rpc = forbidden
                message = await bridge.model_control_refusal({'name': 'release_models', 'arguments': {}})
                self.assertIn('未执行任何卸载', message)
                self.assertIn('unload_model', message)

    async def test_remote_chat_alone_already_makes_global_release_ambiguous(self):
        base = {k: v for k, v in fixtures.CFG.items() if not k.endswith('_port')}
        bridge = brain.Bridge(base)
        self.assertIn('未执行任何卸载', await bridge.model_control_refusal({'name': 'release_models', 'arguments': {}}))


class TaskOwnerHttp(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls = []
        self.servers = []
        self.handlers = []
        self.owner = 'head'
        self.bad_probe = None

        async def backend(reader, writer, role):
            try:
                head = await reader.readuntil(b'\r\n\r\n')
                headers = {k.lower(): v.strip() for k, v in
                           (line.split(b':', 1) for line in head.split(b'\r\n')[1:] if b':' in line)}
                value = json.loads(await reader.readexactly(int(headers[b'content-length'])))
                params = value['params']; name = params['name']; args = params.get('arguments', {})
                self.calls.append((role, name, args))
                if name == 'get_job' and self.bad_probe is not None:
                    result = copy.deepcopy(self.bad_probe)
                elif role == self.owner:
                    result = job_reply(args.get('id'), 'cancelled' if name == 'cancel_job' else 'failed')
                else:
                    result = {'result': {'isError': True, 'content': [{'type': 'text', 'text': 'no such job: '+str(args.get('id'))}]}}
                result['id'] = value['id']; result['jsonrpc'] = '2.0'
                data = json.dumps(result).encode()
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(data)).encode()+b'\r\nConnection: close\r\n\r\n'+data)
                await writer.drain()
            finally:
                writer.close(); await writer.wait_closed()

        ports = {}
        for role in ('head', 'worker'):
            server = await asyncio.start_server(lambda r, w, role=role: backend(r, w, role), '127.0.0.1', 0)
            self.servers.append(server); ports[role] = server.sockets[0].getsockname()[1]
        cfg = {**fixtures.CFG, 'speech_backend_port': ports['worker'], 'transcription_mcp_port': ports['worker'],
               'image_worker_port': ports['worker'], 'video_worker_port': ports['worker'], 'video_backend_port': ports['worker']}
        self.bridge = brain.Bridge(cfg, ports['head'])
        async def client(reader, writer):
            self.handlers.append(asyncio.current_task())
            await self.bridge.client(reader, writer)
        server = await asyncio.start_server(client, '127.0.0.1', 0)
        self.servers.append(server); self.port = server.sockets[0].getsockname()[1]

    async def asyncTearDown(self):
        for server in self.servers:
            server.close(); await server.wait_closed()
        for task in self.handlers:
            if not task.done(): task.cancel()
        await asyncio.gather(*self.handlers, return_exceptions=True)

    async def request(self, name, args):
        value = {'jsonrpc': '2.0', 'id': 17, 'method': 'tools/call', 'params': {'name': name, 'arguments': args}}
        body = json.dumps(value).encode()
        reader, writer = await asyncio.open_connection('127.0.0.1', self.port)
        writer.write(b'POST /mcp HTTP/1.1\r\nHost: local\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)
        await writer.drain(); raw = await asyncio.wait_for(reader.read(), 3)
        writer.close(); await writer.wait_closed()
        self.assertIn(b'200', raw.split(b'\r\n')[0])
        return json.loads(raw.split(b'\r\n\r\n', 1)[1])

    async def test_failed_audio_and_media_job_keeps_original_error_from_owner(self):
        for prefix in ('speech', 'transcription', 'video', 'img', 'image'):
            self.calls.clear(); job_id = prefix+'_old'
            result = await self.request('get_job', {'id': job_id})
            self.assertTrue(result['result']['isError'])
            summary = json.loads(result['result']['content'][0]['text'])
            self.assertEqual(summary['id'], job_id)
            self.assertEqual(summary['error'], 'original decode failure')
            self.assertEqual([role for role, _, _ in self.calls], ['worker', 'head'])

    async def test_waiting_failed_job_is_forwarded_to_its_confirmed_owner(self):
        result = await self.request('get_job', {'id': 'transcription_old', 'wait_s': 2})
        self.assertTrue(result['result']['isError'])
        self.assertEqual([(role, args.get('wait_s')) for role, _, args in self.calls], [('worker', 0), ('head', 0), ('head', 2)])

    async def test_failed_job_cancel_is_sent_once_to_head(self):
        result = await self.request('cancel_job', {'id': 'transcription_old'})
        self.assertFalse(result['result']['isError'])
        self.assertEqual([(role, name) for role, name, _ in self.calls], [('worker', 'get_job'), ('head', 'get_job'), ('head', 'cancel_job')])

    async def test_no_cancel_when_probes_cannot_identify_owner(self):
        for bad in (job_reply('unrelated_id'), {'result': {'isError': False, 'content': []}},
                    {'result': {'isError': True, 'content': [{'type': 'text', 'text': 'service unavailable'}]}}):
            self.calls.clear(); self.bad_probe = bad
            result = await self.request('cancel_job', {'id': 'transcription_old'})
            self.assertTrue(result['result']['isError'])
            self.assertIn('未发送取消', result['result']['content'][0]['text'])
            self.assertTrue(all(name == 'get_job' for _, name, _ in self.calls))

    async def test_release_refusal_does_not_reach_any_backend(self):
        result = await self.request('release_models', {})
        self.assertTrue(result['result']['isError'])
        self.assertIn('未执行任何卸载', result['result']['content'][0]['text'])
        self.assertEqual(self.calls, [])

    async def test_remote_chat_only_release_also_never_contacts_head(self):
        self.bridge.config = {k: v for k, v in self.bridge.config.items() if not k.endswith('_port')}
        result = await self.request('release_models', {})
        self.assertTrue(result['result']['isError'])
        self.assertIn('未执行任何卸载', result['result']['content'][0]['text'])
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
