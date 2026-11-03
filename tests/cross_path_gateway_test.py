import asyncio
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('gateway_cross_path', ROOT/'deploy/jarvis/lan_https.py')
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


class StatusQueryTests(unittest.IsolatedAsyncioTestCase):
    async def test_same_service_shared_across_roles_and_browsers_without_stale_cache(self):
        calls = []
        started, release = asyncio.Event(), asyncio.Event()

        async def fetch(port, path):
            calls.append((port, path)); started.set()
            await release.wait()
            return {'data': [{'id': 'speech', 'state': 'ready'}], 'revision': len(calls)}

        queries = gateway.StatusQueries(fetch)
        pending = [asyncio.create_task(queries.get(8194, '/v1/tools')) for _ in range(6)]
        await started.wait()
        release.set()
        results = await asyncio.gather(*pending)
        self.assertEqual(calls, [(8194, '/v1/tools')])
        results[0]['data'][0]['state'] = 'overwritten by caller'
        self.assertTrue(all(r['data'][0]['state'] == 'ready' for r in results[1:]))
        later = await queries.get(8194, '/v1/tools')
        self.assertEqual(len(calls), 2)
        self.assertEqual(later['revision'], 2)

    async def test_disconnect_does_not_cancel_other_browser(self):
        started, release = asyncio.Event(), asyncio.Event()
        calls = []

        async def fetch(port, path):
            calls.append((port, path)); started.set()
            await release.wait()
            return {'ok': True}

        queries = gateway.StatusQueries(fetch)
        first = asyncio.create_task(queries.get(8194, '/v1/tools'))
        second = asyncio.create_task(queries.get(8194, '/v1/tools'))
        await started.wait()
        first.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await first
        release.set()
        self.assertEqual(await second, {'ok': True})
        self.assertEqual(len(calls), 1)

    async def test_services_and_paths_are_not_confused(self):
        calls = []

        async def fetch(port, path):
            calls.append((port, path))
            await asyncio.sleep(0)
            return {'source': [port, path]}

        queries = gateway.StatusQueries(fetch)
        keys = [(18193, '/v1/tools'), (8194, '/v1/tools'), (8194, '/v1/models')]
        results = await asyncio.gather(*(queries.get(*key) for key in keys))
        self.assertEqual(set(calls), set(keys))
        self.assertEqual([r['source'] for r in results], [list(k) for k in keys])

    async def test_failed_status_is_retried_on_next_poll(self):
        calls = 0

        async def fetch(port, path):
            nonlocal calls
            calls += 1
            await asyncio.sleep(0)
            if calls == 1:
                raise OSError('service unavailable')
            return {'ok': True}

        queries = gateway.StatusQueries(fetch)
        results = await asyncio.gather(queries.get(8194, '/v1/tools'), queries.get(8194, '/v1/tools'), return_exceptions=True)
        self.assertTrue(all(isinstance(r, OSError) for r in results))
        self.assertEqual(calls, 1)
        self.assertEqual(await queries.get(8194, '/v1/tools'), {'ok': True})


if __name__ == '__main__':
    unittest.main()
