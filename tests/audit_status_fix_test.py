import asyncio
import copy
import json
import unittest
from unittest.mock import patch

import model_status_test as fixtures

brain = fixtures.brain


class StatusIntentAudit(unittest.TestCase):
    def test_punctuation_does_not_separate_topic_from_status_question(self):
        for query in ('视频模型，启动了吗？', '语音，暂停了吗？',
                      '图片模型，当前是什么状态？', '图片模型，\n是否已经加载？'):
            with self.subTest(query=query):
                self.assertTrue(brain.model_status_requested({'messages': [{'role': 'user', 'content': query}]}))

    def test_creative_description_does_not_become_a_status_question(self):
        for query in ('生成一张图片，背景是一台模型正在运行',
                      '能不能生成一张猫的图片？', '图片里有几个人？',
                      '生成一段视频，人物在说话，这样可以吗？'):
            with self.subTest(query=query):
                self.assertFalse(brain.model_status_requested({'messages': [{'role': 'user', 'content': query}]}))


class StatusMetadataAudit(unittest.IsolatedAsyncioTestCase):
    async def test_chat_state_matches_mcp_for_known_and_missing_states(self):
        cases = [(None, 'unknown', None), ({}, 'unknown', None),
                 ('loaded', 'ready', True), ('ready', 'ready', True),
                 ('busy', 'busy', True), ('loading', 'loading', None),
                 ('unloaded', 'unloaded', False), ('failed', 'failed', False),
                 ('error', 'failed', False), ('unexpected', 'unknown', None)]
        for upstream, expected, running in cases:
            with self.subTest(upstream=upstream):
                bridge, _ = fixtures.Status().make()
                original = bridge.fetch_json

                async def fetch(remote, path, port=None, timeout=8):
                    if remote:
                        actual = {'id': fixtures.CFG['model']}
                        if upstream is not None:
                            actual['status'] = upstream if isinstance(upstream, dict) else {'value': upstream}
                        return {'data': [actual]}
                    if port == 8196:
                        return {'data': [{'id': 'vid', 'kind': 'video'}, {'id': 'im', 'kind': 'image'}]}
                    if port is None:
                        return {'data': []}
                    return await original(remote, path, port, timeout)

                bridge.fetch_json = fetch
                snapshot = json.loads((await bridge.model_list(copy.deepcopy(fixtures.RPC)))['result']['content'][0]['text'])
                mcp = next(m for m in snapshot['models'] if m['kind'] == 'chat')
                for path in ('/tools', '/models'):
                    model = (await bridge.metadata(path))['data'][0]
                    self.assertEqual(model['state'], expected)
                    self.assertIs(model['running'], running)
                    self.assertEqual((model['state'], model['running']), (mcp['state'], mcp['running']))

    async def test_shared_worker_is_one_snapshot_even_during_model_switch(self):
        for path in ('/models', '/tools'):
            bridge = brain.Bridge({k: v for k, v in fixtures.CFG.items() if k not in ('speech_backend_port', 'transcription_backend_port')})
            calls = []

            async def fetch(remote, route, port=None, timeout=8):
                if remote:
                    return {'data': [{'id': fixtures.CFG['model'], 'status': 'loaded'}]}
                if port == 8196:
                    calls.append(port)
                    first = len(calls) == 1
                    return {'data': [{'id': 'vid', 'kind': 'video', 'state': 'ready' if first else 'unloaded'},
                                     {'id': 'im', 'kind': 'image', 'state': 'unloaded' if first else 'ready'}]}
                return {'data': []}

            bridge.fetch_json = fetch
            models = {m['kind']: m for m in (await bridge.metadata(path))['data']}
            self.assertEqual(calls, [8196])
            self.assertEqual((models['video']['state'], models['image']['state']), ('ready', 'unloaded'))

    async def test_metadata_distinct_nodes_start_together(self):
        bridge = brain.Bridge(fixtures.CFG)
        started = set()
        barrier = asyncio.Event()

        async def fetch(remote, path, port=None, timeout=8):
            started.add(('brain' if remote else 'local', port))
            if len(started) == 5:
                barrier.set()
            await barrier.wait()
            if remote:
                return {'data': [{'id': fixtures.CFG['model'], 'status': 'loaded'}]}
            kind = {8194: 'speech', 18795: 'transcription'}.get(port)
            if kind:
                return {'data': [{'id': kind, 'kind': kind, 'state': 'ready'}]}
            if port == 8196:
                return {'data': [{'id': 'vid', 'kind': 'video'}, {'id': 'im', 'kind': 'image'}]}
            return {'data': []}

        bridge.fetch_json = fetch
        await asyncio.wait_for(bridge.metadata('/tools'), 0.5)
        self.assertEqual(len(started), 5)

    async def test_mcp_distinct_nodes_start_together_and_share_worker(self):
        bridge, calls = fixtures.Status().make()
        original_fetch, original_rpc = bridge.fetch_json, bridge.local_rpc
        started = set()
        barrier = asyncio.Event()

        async def wait(key):
            started.add(key)
            if len(started) == 6:
                barrier.set()
            await barrier.wait()

        async def fetch(remote, path, port=None, timeout=8):
            await wait(('fetch', remote, port))
            return await original_fetch(remote, path, port, timeout)

        async def rpc(port, value, timeout=15):
            await wait(('rpc', port))
            return await original_rpc(port, value, timeout)

        bridge.fetch_json, bridge.local_rpc = fetch, rpc
        await asyncio.wait_for(bridge.model_list(copy.deepcopy(fixtures.RPC)), 0.5)
        self.assertEqual(calls.count(8196), 1)
        self.assertEqual(len(started), 6)

    async def test_slow_metadata_worker_is_unknown_within_overall_deadline(self):
        bridge = brain.Bridge({k: v for k, v in fixtures.CFG.items() if k not in ('speech_backend_port', 'transcription_backend_port')})
        cancelled = []

        async def fetch(remote, path, port=None, timeout=8):
            if remote:
                return {'data': [{'id': fixtures.CFG['model'], 'status': 'loaded'}]}
            if port == 8196:
                try:
                    await asyncio.Event().wait()
                finally:
                    cancelled.append(port)
            return {'data': []}

        bridge.fetch_json = fetch
        with patch.object(brain, 'STATUS_QUERY_TIMEOUT', 0.025):
            data = (await asyncio.wait_for(bridge.metadata('/tools'), 0.5))['data']
        self.assertEqual(cancelled, [8196])
        self.assertEqual([m['state'] for m in data if m['kind'] in ('image', 'video')], ['unknown', 'unknown'])

    async def test_slow_head_does_not_leave_other_requests_pending(self):
        bridge, _ = fixtures.Status().make()
        original = bridge.local_rpc
        cancelled = []

        async def rpc(port, value, timeout=15):
            if port == bridge.backend:
                try:
                    await asyncio.Event().wait()
                finally:
                    cancelled.append(port)
            return await original(port, value, timeout)

        bridge.local_rpc = rpc
        with patch.object(brain, 'STATUS_QUERY_TIMEOUT', 0.025):
            with self.assertRaises(TimeoutError):
                await asyncio.wait_for(bridge.model_list(copy.deepcopy(fixtures.RPC)), 0.5)
        self.assertEqual(cancelled, [bridge.backend])


if __name__ == '__main__':
    unittest.main()
