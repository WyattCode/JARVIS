import asyncio
import json
import unittest
from unittest.mock import patch

import model_status_test as fixtures

brain = fixtures.brain


class ChatConnectionCancellation(unittest.IsolatedAsyncioTestCase):
    async def test_disconnect_during_connect_never_submits_mcp_or_http_chat(self):
        for mcp in (False, True):
            with self.subTest(mcp=mcp):
                seen = []
                done = asyncio.Event()
                connecting = asyncio.Event()
                release = asyncio.Event()
                handlers = []

                async def upstream(reader, writer):
                    try:
                        seen.append(await reader.read(65536))
                    finally:
                        writer.close(); await writer.wait_closed(); done.set()

                remote = await asyncio.start_server(upstream, '127.0.0.1', 0)
                upstream_port = remote.sockets[0].getsockname()[1]
                cfg = {'model': 'test-chat', 'name': 'Test Chat', 'api_key': 'test-only',
                       'base_url': f'http://127.0.0.1:{upstream_port}/v1'}
                bridge = brain.Bridge(cfg)

                async def client(reader, writer):
                    handlers.append(asyncio.current_task())
                    await bridge.client(reader, writer)

                server = await asyncio.start_server(client, '127.0.0.1', 0)
                port = server.sockets[0].getsockname()[1]
                original = asyncio.open_connection

                async def delayed(host, target, *args, **kwargs):
                    if target == upstream_port:
                        connecting.set()
                        await release.wait()
                    return await original(host, target, *args, **kwargs)

                try:
                    with patch.object(brain.asyncio, 'open_connection', side_effect=delayed):
                        reader, writer = await original('127.0.0.1', port)
                        value = ({'jsonrpc': '2.0', 'id': 7, 'method': 'tools/call',
                                  'params': {'name': 'chat', 'arguments': {'prompt': 'hello'}}} if mcp
                                 else {'stream': False, 'messages': [{'role': 'user', 'content': 'hello'}]})
                        body = json.dumps(value).encode()
                        path = '/mcp' if mcp else '/v1/chat/completions'
                        writer.write(f'POST {path} HTTP/1.1\r\nHost: local\r\nContent-Length: {len(body)}\r\n\r\n'.encode()+body)
                        await writer.drain(); await asyncio.wait_for(connecting.wait(), 1)
                        writer.close(); await writer.wait_closed()
                        # Allow the server's StreamReader to observe the TCP EOF
                        # while the deliberately delayed connect is still pending.
                        await asyncio.sleep(0.01)
                        release.set()
                        await asyncio.wait_for(done.wait(), 1)
                        await asyncio.wait_for(asyncio.gather(*handlers), 1)
                    self.assertEqual(seen, [b''])
                finally:
                    release.set()
                    server.close(); remote.close()
                    await server.wait_closed(); await remote.wait_closed()
                    for task in handlers:
                        if not task.done(): task.cancel()
                    await asyncio.gather(*handlers, return_exceptions=True)


if __name__ == '__main__':
    unittest.main()
