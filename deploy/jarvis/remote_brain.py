#!/usr/bin/env python3
"""Loopback-only Jarvis chat bridge. Credentials stay on the server.

Chat goes to the configured LAN model; speech, media and other APIs stay local.
Existing model daemons are never started, stopped or reconfigured here.
"""
import argparse
import asyncio
import collections
from functools import lru_cache
from datetime import datetime
from zoneinfo import ZoneInfo
import http.client
import json
import mimetypes
import os
import tempfile
import resource
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools/speech/drama3'))
from voice_catalog import describe_voices, preview_audio
sys.path.append(str(Path(__file__).resolve().parent))
from video_prompt_guard import prepare as prepare_video_prompt
from png_integrity import (validate_png, MAX_BYTES as MAX_PNG_BYTES,
    PNG_RECOVERY_DOWNLOAD_TIMEOUT, PNG_RECOVERY_DOWNLOAD_BUDGET, PNG_RECOVERY_BRIDGE_TIMEOUT)
from bounded_http import request_json, read_json_response
from chat_stream_guard import guarded_stream
from voice_output_policy import VOICE_POLICY, VoiceStream, is_voice as current_model_is_voice, voice_messages, text_of

EFFORTS = {'none', 'low', 'medium', 'high'}
def is_voice(body, config):
    if current_model_is_voice(body, config):
        return True
    model = body.get('model')
    return isinstance(model, str) and model in {m + '--jarvis-' + e for m in config.get('legacy_chat_models', []) for e in EFFORTS}


MODEL_GUIDANCE = (
    '模型状态以本次实时查询为准，不能根据历史记录或模型名称推测已加载、常驻、暂停或恢复。'
    '回答模型状态时使用本次实时快照或模型列表工具；都不可用时说明无法确认。'
    '媒体模型按需加载并可能排队；换出后不保证立即自动恢复。'
    '预留、手动卸载等操作的恢复行为以该操作的实际结果为准。'
    '语音合成与听写属于独立服务，具体模型及状态以实时查询结果为准，不要臆测。'
    '模型名称可以保留，状态和说明用简体中文，不朗读英文状态字段。'
    '语音暂停状态属于语音主机，不属于远端图片或视频服务器。'
    '实时状态不能证明响应速度，也不能保证其他负载条件下语音不受影响。'
    '内存优先使用吉字节表达，预算未设定不等于预算为零。'
)


def model_guidance(config):
    if config.get('local_media_trial'):
        return ('当前为聊天分机、媒体本机测试：聊天大模型运行在配置的远端主机；语音合成、Whisper识别、图片和视频都在本机，共用GPU及统一内存。'
                '模型状态以本次实时查询为准，不得把代理进程当成独立计算设备，也不要把本机内存重复相加。'
                '图片和视频共用调度队列，按需换出；语音优先保留，但并发速度须以实际测试为准。'
                '语音模型的控制权限以工具返回为准，不要臆测操作已成功。中文回复使用简体中文。')
    if config.get('single_host_trial'):
        return ('当前处于单机测试：聊天、语音合成、Whisper识别、图片和视频都在同一台本地DGX，共用GPU及统一内存。'
                '模型状态以本次实时查询为准，不得把代理进程当成独立计算设备，也不要把同一主机内存重复相加。'
                '图片和视频共用调度队列，按需换出；聊天和语音优先保留，但并发速度须以实际测试为准。'
                '语音模型的控制权限以工具返回为准，不要臆测操作已成功。中文回复使用简体中文。')
    same = config.get('image_worker_port') and config.get('image_worker_port') == config.get('video_worker_port')
    voice_separate = config.get('speech_backend_port') or config.get('transcription_backend_port')
    return MODEL_GUIDANCE + ('图片与视频共用远端机器和调度器。' if same else '') + ('由独立服务管理的语音模型不支持通过该模型工具启停或预留，应按工具结果如实说明。' if voice_separate else '')


class ImageIntegrityError(OSError):
    pass


def file_identity(file):
    stat = file.stat()
    return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)


@lru_cache(maxsize=128)
def validated_png_file(path, identity):
    file = Path(path)
    if file_identity(file) != identity or identity[2] > MAX_PNG_BYTES:
        raise ValueError('cached PNG changed')
    validate_png(file.read_bytes())
    if file_identity(file) != identity:
        raise ValueError('cached PNG changed during validation')
    return True


def clock_context():
    # Refresh at the common chat gateway, including voice and tool follow-up turns.
    now = datetime.now(ZoneInfo('Asia/Shanghai'))
    weekday = ('星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日')[now.weekday()]
    return (
        'Jarvis server clock context (refreshed for this request):\n'
        f'Current date: {now:%Y-%m-%d} ({weekday}). Current time: {now:%H:%M:%S}.\n'
        'Time zone: Asia/Shanghai (UTC+08:00). This is the configured service time zone, '
        'not evidence of the user physical location. Use it for today, yesterday, tomorrow '
        'and relative dates unless the user specifies another time zone. '
        'This clock supersedes dates inferred from training data or earlier conversation. '
        'A fictional or historical date in a task does not change the actual current date. '
        'The clock does not provide live news, weather, prices or knowledge of device state. '
        'Use available tools to verify live facts; if verification is unavailable, say so '
        'instead of claiming to have checked. Do not claim an action succeeded without a tool result. '
        '中文回复统一使用简体中文；时区名称不代表用户所在地，也不决定回复语言。'
    )


def creative_request(user):
    return bool(re.search(r'(?:生成|制作|画|绘制|做|设计).{0,12}(?:一张|一幅|一段|一个|一部|张|幅|段|个).{0,40}(?:图|画|视频|片)',user))


def status_clauses(user):
    start=0
    for match in re.finditer(r'[，,。；;\n]|同时|顺便|另外|然后|并且|以及|并(?=(?:请|再)?(?:查|看|问|确认|检查|查询|告诉))',user):
        yield user[start:match.start()];start=match.end()
    yield user[start:]


def model_status_requested(body):
    messages=body.get('messages',[]) if isinstance(body,dict) else []
    if not isinstance(messages,list):return False
    user=next((text_of(m) for m in reversed(messages) if isinstance(m,dict) and m.get('role')=='user'),'')
    # Separate coordinated requests before checking for a creative prompt;
    # one clause may request media while another asks for live status.
    subject_any=re.search(r'模型|大模型|听写|语音|图片|视频|生图|出图|画图|出片|\b(?:ASR|TTS|model)\b',user,re.I)
    creative_seen=False
    topic=None
    for clause in status_clauses(user):
        status=status_clause_requested(clause)
        # A pause in speech often separates the topic from its question.
        # Carry only an explicit non-creative topic, not a scene description.
        if not status and topic and not creative_seen and re.search(r'是否|有没有|是不是|能不能|能否|吗|么|嘛|[？?]',clause):
            status=status_clause_requested(topic+clause)
        # A later scene description is not a second request merely because it
        # mentions a model or its state; require a question or checking verb.
        if status and creative_seen and not re.search(r'查一下|查询|检查|查下|查查|查看|看看|确认|告诉我|问下|是否|有没有|能不能|能否|可不可以|是不是|会不会|吗|么|嘛|[？?]',clause):status=False
        if status:return True
        if subject_any and re.search(r'(?:查一下|查询|检查|查下|查查|查看|看看|确认).{0,15}(?:状态|能不能用|可不可以用|是否正常|是不是正常|有没有加载|启动了吗)',clause):return True
        creative_seen=creative_seen or creative_request(clause)
        if not creative_seen:
            subject=re.search(r'模型|大模型|听写|语音|图片|视频|生图|出图|画图|出片|\b(?:ASR|TTS|model)\b',clause,re.I)
            if subject:topic=subject.group()
    return False


def status_clause_requested(user):
    # A concrete creative request may mention "运行" or "状态" as part of
    # its scene. Do not query servers unless it also explicitly asks about them.
    creative=creative_request(user)
    explicit=re.search(r'(?:模型|服务|语音识别|听写).{0,10}(?:状态|启动|加载|运行|内存|显存|预算|占用|暂停)|(?:查询|检查|查下|查看).{0,10}(?:模型|服务|语音状态)',user)
    if not explicit:explicit=re.search(r'(?:语音|听写).{0,8}(?:是否|有没有|会不会).{0,5}(?:暂停|中断|受影响)|(?:查询|检查|查下|查看|看看).{0,10}语音.{0,5}(?:暂停|状态)',user)
    if creative and not explicit:return False
    subject=re.search(r'模型|大模型|听写|语音|图片|视频|生图|出图|画图|出片|\b(?:ASR|TTS|model)\b',user,re.I)
    action=re.search(r'状态|常驻|加载|运行|可用|能用|能不能用|能否使用|可不可以用|可以用|还能用|就绪|换出|卸载|驻留|暂停|中断|预留|内存|显存|预算|占用|启动|在线|离线|status|loaded|running|available',user,re.I)
    if not action:action=re.search(r'(?:能否|能不能|可不可以|可以|还能|能).{0,10}(?:生成|生图|出图|画图|做视频|做图|出片)|(?:生图|出图|画图|出片|图片|视频|语音).{0,8}(?:还行吗|能用吗|通不通|正常吗|正常么)|(?:视频|图片).{0,12}影响.{0,8}语音',user)
    if not action:action=re.search(r'(?:模型|服务|听写|语音识别).{0,12}(?:情况|信息|在哪|哪个|哪些|几个|几种|什么|多少|查看|查询|查下|查查|检查|看看|有没有|是否|是不是|正常)|(?:查看|查询|查下|查查|检查|看看|什么|多少|哪些).{0,12}(?:模型|服务|听写|语音识别)',user)
    return bool(subject and action)


STATUS_QUERY_TIMEOUT = 3.0


def remote_chat_state(actual):
    status=actual.get('status', actual.get('state'))
    if status is None and isinstance(actual.get('running'), bool):
        return ('ready', True) if actual['running'] else ('unloaded', False)
    status=status.get('value') if isinstance(status,dict) else status
    if status in ('loaded','ready'):return 'ready',True
    if status=='busy':return 'busy',True
    if status=='unloaded':return 'unloaded',False
    if status in ('failed','error'):return 'failed',False
    return ('loading' if status=='loading' else 'unknown'),None


async def collect_status_queries(queries):
    # Start distinct endpoints together; one slow node cannot add a fresh
    # timeout after every other node. Socket timeouts also bound worker threads.
    results=await asyncio.gather(*(asyncio.wait_for(query,STATUS_QUERY_TIMEOUT) for query in queries.values()),return_exceptions=True)
    return dict(zip(queries,results))


def status_result(results,key):
    value=results[key]
    if isinstance(value,BaseException):raise value
    return value


def chinese_status_facts(snapshot):
    kinds={'chat':'对话','speech':'语音合成','transcription':'语音识别','image':'图片','video':'视频'}
    states={'ready':'已加载且可用','busy':'已加载且正在处理','loading':'正在加载','unloaded':'未加载',
            'failed':'服务异常或不可用','unavailable':'无法查询','unknown':'状态未知'}
    models=[]
    for m in snapshot.get('models',[]):
        kind=m.get('kind');state=m.get('state')
        item={'类别':kinds.get(kind,'其他'),'模型':m.get('id'),'设备':m.get('machine','主机'),
              '状态':states.get(state,'状态未知')}
        if type(m.get('keep_loaded')) is bool:item['配置常驻']=m['keep_loaded']
        if m.get('last_error'):item['状态说明']=m['last_error']
        if kind in ('image','video') and isinstance(m.get('resident_bytes'),int):item['调度器报告已驻留字节']=m['resident_bytes']
        models.append(item)
    def memory(value, voice=False):
        if not isinstance(value,dict):return {'语音暂停':'未知'} if voice else None
        result={}
        for key,name in (('budget_bytes','预算'),('mem_available_bytes','系统可用'),('reserve_bytes','预留')):
            amount=value.get(key)
            if type(amount) is not int or amount<0:continue
            if key=='budget_bytes' and amount==0:result['预算说明']='未设置固定预算';continue
            result[name+'字节']=amount;result[name+'约合吉字节']=round(amount/(2**30),2)
        if voice:
            pause=value.get('voice_paused')
            result['语音暂停']='是' if pause is True else '否' if pause is False else '未知'
        return result
    return {'模型列表':models,'语音主机状态':memory(snapshot.get('voice_coordinator_memory',snapshot.get('memory')),voice=True),
            '图片服务器内存':memory(snapshot.get('image_worker_memory')),
            '视频服务器内存':memory(snapshot.get('video_worker_memory'))}


def chat_body(body, config):
    if not isinstance(body, dict):
        raise ValueError('request must be a JSON object')
    out = dict(body)
    messages = out.get('messages', [])
    if not isinstance(messages, list) or any(not isinstance(m, dict) for m in messages):
        raise ValueError('messages must be an array of objects')
    messages = list(messages)
    index = 0
    while index < len(messages) and messages[index].get('role') in ('system', 'developer'):
        index += 1
    voice = is_voice(out, config)
    managed = config.get('image_worker_port') or config.get('speech_backend_port') or config.get('transcription_backend_port')
    guidance = '\n' + model_guidance(config) if managed else ''
    messages.insert(index, {'role': 'system', 'content': clock_context() + guidance + ('\n' + VOICE_POLICY if voice else '')})
    if voice:messages = voice_messages(messages)
    out['messages'] = messages
    selected = out.get('model')
    aliases = {model + '--jarvis-' + e: e for model in [config['model'], *config.get('legacy_chat_models', [])] for e in EFFORTS}
    routed_effort = aliases.get(selected) if isinstance(selected, str) else None
    if routed_effort is not None:
        out['model'] = config['model']
    if out.get('model') not in (None, '', config['model'], config['name'], 'qwen3.8-27b', 'qwen3.8-flash-next-iq3_s' if config.get('single_host_trial') else config['model']):
        raise ValueError('unknown chat model')
    out['model'] = config['model']
    kwargs = out.get('chat_template_kwargs') or {}
    if not isinstance(kwargs, dict):
        raise ValueError('chat_template_kwargs must be an object')
    kwargs = dict(kwargs)
    effort = routed_effort if routed_effort is not None else out.get('reasoning_effort')
    if effort is None:
        effort = config.get('reasoning_effort', 'high')
    if kwargs.get('enable_thinking') is False:
        effort = 'none'
    if not isinstance(effort, str) or effort not in EFFORTS:
        raise ValueError('reasoning_effort must be none, low, medium or high')
    out['reasoning_effort'] = effort
    kwargs['enable_thinking'] = effort != 'none'
    out['chat_template_kwargs'] = kwargs
    if 'max_tokens' not in out and 'max_completion_tokens' not in out:
        out['max_tokens'] = 8192
    return out


def mcp_chat_body(args):
    if not isinstance(args, dict):raise ValueError('聊天工具参数必须为对象')
    messages = []
    if 'system' in args:
        if not isinstance(args['system'], str):raise ValueError('system 必须为文本')
        messages.append({'role':'system','content':args['system']})
    if 'messages' in args:
        if not isinstance(args['messages'], list):raise ValueError('messages 必须为消息数组')
        messages.extend(args['messages'])
    if 'prompt' in args:
        if not isinstance(args['prompt'], str):raise ValueError('prompt 必须为文本')
        messages.append({'role':'user','content':args['prompt']})
    if not messages or not any(k in args for k in ('prompt','messages')):
        raise ValueError('请提供 prompt 或 messages')
    body = {k:args[k] for k in ('model','max_tokens','temperature','top_p','stop','seed','tools','tool_choice','response_format') if k in args}
    body.update(messages=messages,stream=False)
    if 'reasoning' in args:
        if type(args['reasoning']) is not bool:raise ValueError('reasoning 必须为布尔值')
        body['chat_template_kwargs'] = {'enable_thinking':args['reasoning']}
        if not args['reasoning']:body['reasoning_effort']='none'
    return body


def mcp_text_result(ident, text, error=False):
    return {'jsonrpc':'2.0','id':ident,'result':{'isError':error,'content':[{'type':'text','text':text}]}}


def mcp_chat_result(ident, completion, request, voice=False):
    if not isinstance(completion, dict) or completion.get('error'):
        raise ValueError('聊天服务未返回有效回复')
    choices = completion.get('choices')
    if not isinstance(choices, list) or not choices or any(not isinstance(c,dict) or not isinstance(c.get('message'),dict) for c in choices):
        raise ValueError('聊天服务返回的回复格式无效')
    if any(c.get('finish_reason') in ('length','content_filter') for c in choices):
        raise ValueError('回复未完整生成，请调整输出长度或重试')
    if voice:
        filt=VoiceStream(request)
        filt.tool_seen=any(c['message'].get('tool_calls') for c in choices)
        for i,c in enumerate(choices):
            msg=c['message'];content=msg.get('content')
            if isinstance(content,str):msg['content']=filt.feed(i,content,last=True)
            for key in ('reasoning','reasoning_content','analysis'):msg.pop(key,None)
    message=choices[0]['message'];text=message.get('content')
    if not isinstance(text,str) or not text.strip():
        calls=message.get('tool_calls')
        if not isinstance(calls,list) or not calls:raise ValueError('聊天服务返回空回复，请重试')
        text=json.dumps(calls,ensure_ascii=False)
    result=mcp_text_result(ident,text)
    result['result']['content'].append({'type':'text','text':json.dumps(completion,ensure_ascii=False)})
    return result


async def relay(reader, writer):
    while data := await reader.read(65536):
        writer.write(data)
        await writer.drain()


def canonical_job_file(url):
    if not isinstance(url,str):return url
    try:path=urllib.parse.urlsplit(url).path
    except ValueError:return url
    # File paths are exported relative to the gateway, never the internal
    # worker host. The public gateway upgrades these to trusted HTTPS links.
    if re.fullmatch(r'/v1/files/(?:img|image|video|speech|transcription)_[A-Za-z0-9_-]+/[A-Za-z0-9][A-Za-z0-9_.-]*',path):return path
    return url


def normalize_mcp_files(value):
    if not isinstance(value,dict) or not isinstance(value.get('result'),dict):return value
    blocks=value['result'].get('content')
    if not isinstance(blocks,list):return value
    for block in blocks:
        if not isinstance(block,dict):continue
        if block.get('type')=='resource_link':
            if 'uri' in block:block['uri']=canonical_job_file(block['uri'])
        elif block.get('type')=='text' and isinstance(block.get('text'),str):
            try:job=json.loads(block['text'])
            except ValueError:continue
            if not isinstance(job,dict) or not isinstance(job.get('id'),str) or not re.fullmatch(r'(?:img|image|video|speech|transcription)_[A-Za-z0-9_-]+',job['id']):continue
            changed=False
            for key in ('files','urls'):
                if isinstance(job.get(key),list):
                    job[key]=[canonical_job_file(url) for url in job[key]];changed=True
            if changed:block['text']=json.dumps(job,ensure_ascii=False)
    return value


def normalize_job_arguments(params):
    if params.get('name') not in ('get_job','cancel_job'):return
    args=params.get('arguments')
    if not isinstance(args,dict):raise ValueError('任务参数必须为对象')
    identifiers=[args[key] for key in ('id','job_id') if key in args]
    if not identifiers or any(not isinstance(ident,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',ident) for ident in identifiers):
        raise ValueError('任务 id 必须为非空有效字符串')
    if any(ident!=identifiers[0] for ident in identifiers):raise ValueError('id 与 job_id 指向不同任务，未执行操作')
    args['id']=identifiers[0];args.pop('job_id',None)


class Bridge:
    def __init__(self, config, backend=8190):
        self.config = config
        self.backend = backend
        self.base = urllib.parse.urlsplit(config['base_url'])
        if self.base.scheme not in ('http', 'https') or not self.base.hostname or self.base.username or self.base.password:
            raise ValueError('invalid upstream URL')
        self.recent = collections.deque(maxlen=20)
        self.history = json.loads(Path(config['job_history']).read_text()) if config.get('job_history') else {}
        self.artifact_root = Path(config['artifact_root']).resolve() if config.get('artifact_root') else None
        self.png_repairs = {}

    async def fetch_json(self, remote, path, port=None, timeout=8):
        base = self.config['base_url'].rstrip('/') if remote else f'http://127.0.0.1:{port or self.backend}/v1'
        headers = {'Authorization': 'Bearer ' + self.config['api_key']} if remote else {}
        return await request_json(base+path,headers=headers,timeout=timeout)

    def video_ports(self, path, method):
        if path.startswith(('/v1/jobs/', '/v1/files/')):
            audio = self.audio_job_port(path.split('/')[3])
            if audio:
                return list(dict.fromkeys([audio, self.backend])) if method in ('GET', 'HEAD', 'DELETE') else [audio]
        image_port = self.config.get('image_worker_port')
        if image_port:
            if path.startswith('/v1/images/') or path.startswith('/v1/tools/qwen-image-2.1-turbo/'):
                return [image_port]
            if path.startswith(('/v1/files/img_', '/v1/jobs/img_', '/v1/files/image_', '/v1/jobs/image_')):
                return list(dict.fromkeys([image_port, self.backend])) if method in ('GET', 'DELETE', 'HEAD') else [image_port]
        if path == '/v1/audio/speech' and self.config.get('speech_backend_port'):
            return [self.config['speech_backend_port']]
        if path == '/v1/audio/transcriptions' and self.config.get('transcription_backend_port'):
            return [self.config['transcription_backend_port']]
        if not self.config.get('video_worker_port'):
            return [self.backend]
        worker = self.config['video_worker_port']
        if path.startswith('/v1/tools/minimax-h3/'):
            return [worker]
        if path == '/v1/videos' or path.startswith(('/v1/videos/', '/v1/jobs/video_', '/v1/files/video_')):
            ports = [self.config['video_backend_port']]
            if method in ('GET', 'HEAD', 'DELETE'):
                ports += [self.backend, worker]  # old head jobs and direct worker MCP jobs retain their IDs
            return list(dict.fromkeys(ports))
        return [self.backend]

    def audio_job_port(self, job_id):
        if job_id.startswith('speech_'):
            return self.config.get('speech_backend_port')
        if job_id.startswith('transcription_') and self.config.get('transcription_backend_port'):
            return self.config.get('transcription_mcp_port') or self.config.get('speech_backend_port')
        return None

    async def prepare_audio_tool(self, params):
        """Verify the MCP adapter serves the same model as the HTTP endpoint."""
        name = params.get('name')
        if name not in ('transcribe_audio', 'synthesize_speech'):return None
        kind = 'transcription' if name == 'transcribe_audio' else 'speech'
        endpoint = self.config.get(kind + '_backend_port')
        if not endpoint or endpoint == self.backend:return None
        adapter = (self.config.get('transcription_mcp_port') or self.config.get('speech_backend_port')) if kind == 'transcription' else endpoint
        if not adapter:return '当前独立听写服务尚未配置 MCP 接口，请使用音频转写接口。'
        args = params.get('arguments')
        if not isinstance(args, dict):return '工具参数必须为对象。'
        try:
            ports = list(dict.fromkeys([endpoint, adapter]))
            replies = await asyncio.wait_for(asyncio.gather(*(self.fetch_json(False, '/tools', port, timeout=1.5) for port in ports)), 2)
            models = {port: [m for m in reply['data'] if isinstance(m, dict) and m.get('kind') == kind and isinstance(m.get('id'), str) and m['id'].strip()] for port, reply in zip(ports, replies)}
            selected = args.get('model')
            if selected is None or selected == '':
                candidates = models[endpoint]
                capability = 'speech_to_text' if kind == 'transcription' else 'text_to_speech'
                preferred = [m for m in candidates if capability in (m.get('default_for') or [])]
                candidates = preferred or candidates
                if len(candidates) != 1:return '无法唯一确定语音模型，请指定当前模型列表中的模型。'
                selected = candidates[0]['id']
            if not isinstance(selected, str) or not all(any(m['id'] == selected for m in models[p]) for p in ports):
                return '所选模型不属于当前语音服务，或 MCP 与音频接口配置不一致。'
            args['model'] = selected
        except (OSError, ValueError, TypeError, KeyError, AttributeError, asyncio.TimeoutError):
            return '语音服务状态暂不可查询，未提交任务，请稍后重试。'
        return None

    def mcp_ports(self, value):
        if not isinstance(value, dict):
            return [self.backend]
        params = value.get('params') or {}
        if value.get('method') != 'tools/call' or not isinstance(params, dict):
            return [self.backend]
        name = params.get('name')
        args = params.get('arguments') or {}
        if not isinstance(args, dict):
            return [self.backend]
        if name in ('synthesize_speech', 'list_voices') and self.config.get('speech_backend_port'):
            return [self.config['speech_backend_port']]
        if name == 'transcribe_audio' and self.config.get('transcription_backend_port'):
            return [self.config.get('transcription_mcp_port') or self.config.get('speech_backend_port') or self.config['transcription_backend_port']]
        audio = self.audio_job_port(str(args.get('id', args.get('job_id', ''))))
        if name in ('get_job', 'cancel_job') and audio:
            return list(dict.fromkeys([audio, self.backend]))
        if self.config.get('image_worker_port'):
            image = args.get('model') in ('image', 'qwen-image-2.1-turbo')
            if name == 'generate_image' or (image and name in ('reserve_for', 'load_model', 'unload_model')):
                return [self.config['image_worker_port']]
            if name in ('get_job', 'cancel_job') and str(args.get('id', args.get('job_id', ''))).startswith(('img_', 'image_')):
                return [self.config['image_worker_port'], self.backend]
        if not self.config.get('video_worker_port'):
            return [self.backend]
        video = args.get('model') in ('video', 'minimax-h3')
        if name == 'generate_video' or (video and name in ('reserve_for', 'load_model', 'unload_model')):
            return [self.config['video_worker_port']]
        if name in ('get_job', 'cancel_job') and str(args.get('id', args.get('job_id', ''))).startswith('video_'):
            return [self.config['video_worker_port']]
        return [self.backend]

    @staticmethod
    def rpc_job_summary(value, job_id):
        """A failed job still belongs to its host; an MCP error alone does not."""
        if not isinstance(value,dict) or value.get('error'):return None
        result=value.get('result')
        if not isinstance(result,dict) or not isinstance(result.get('content'),list):return None
        for block in result['content']:
            if not isinstance(block,dict) or block.get('type')!='text' or not isinstance(block.get('text'),str):continue
            try:summary=json.loads(block['text'])
            except (ValueError,TypeError):continue
            if (isinstance(summary,dict) and summary.get('id')==job_id
                    and summary.get('status') in ('queued','in_progress','completed','failed','cancelled')):
                return summary
        return None

    async def model_control_refusal(self, params):
        """Never route control of an independently managed model to the head daemon."""
        if not isinstance(params,dict):return None
        if params.get('name')=='release_models':
            split=bool(self.config.get('base_url')) or any(self.config.get(key) and self.config[key]!=self.backend for key in ('image_worker_port','video_worker_port','speech_backend_port','transcription_backend_port'))
            if split:
                return '当前模型跨独立服务部署，不能执行无范围的全部卸载；未执行任何卸载。请先查询 list_models，再用 unload_model 指定可管理的图片或视频模型。独立服务不能由此工具统一释放。'
            return None
        if params.get('name') not in ('reserve_for','load_model','unload_model'):return None
        args=params.get('arguments')
        if params['name'] in ('load_model','unload_model') and isinstance(args,dict) and 'dry_run' in args:
            return 'load_model 和 unload_model 不支持 dry_run，未执行操作。需要预览内存安排时请使用 reserve_for 并设置 dry_run=true。'
        if not isinstance(args,dict) or not isinstance(args.get('model'),str):return None
        target=args['model']
        if target in (self.config.get('model'),'chat'):
            return '远端对话模型由独立服务管理，当前模型工具不支持对此模型加载、卸载或预留。'
        voice_port=self.config.get('speech_backend_port');asr_port=self.config.get('transcription_backend_port')
        voice_separate=bool(voice_port and voice_port!=self.backend)
        asr_separate=bool(asr_port and asr_port!=self.backend)
        if not voice_separate and not asr_separate:return None
        # Known deployed IDs and kind aliases fail closed even if an endpoint
        # is offline; live lists also support future renamed models.
        if voice_separate and target in ('speech','text_to_speech','fishaudio/drama-3'):
            return '语音合成由独立服务管理，当前模型工具不支持对此服务加载、卸载或预留。'
        if asr_separate and target in ('transcription','speech_to_text','qwen3-asr-1.7b'):
            return '语音识别由独立服务管理，当前模型工具不支持对此服务加载、卸载或预留。'
        if target in ('image','qwen-image-2.1-turbo','video','minimax-h3'):return None
        expected={}
        if voice_separate:expected.setdefault(voice_port,set()).add('speech')
        if asr_separate:expected.setdefault(asr_port,set()).add('transcription')
        ports=list(expected)
        results=await asyncio.gather(*(self.fetch_json(False,'/tools',p,timeout=1.5) for p in ports),return_exceptions=True)
        uncertain=False
        for port,result in zip(ports,results):
            if not isinstance(result,dict) or not isinstance(result.get('data'),list):uncertain=True;continue
            entries=result['data']
            valid=[m for m in entries if isinstance(m,dict) and isinstance(m.get('id'),str) and isinstance(m.get('kind'),str)]
            if len(valid)!=len(entries):uncertain=True
            if not expected[port].issubset({m['kind'] for m in valid}):uncertain=True
            for model in valid:
                if model['id']==target and model['kind'] in ('speech','transcription'):
                    return '该语音服务由独立进程管理，当前模型工具不支持对此服务加载、卸载或预留。'
        if uncertain:return '部分语音服务状态暂不可查询，无法确认模型归属，请稍后重试。'
        return None

    @staticmethod
    def http_model_control(path):
        decoded=urllib.parse.unquote(path,errors='strict')
        if not decoded.startswith('/v1/tools/'):return None
        rest=decoded[len('/v1/tools/'):]
        if any(c in decoded for c in ('%','?','#','\\')) or not decoded.isascii() or any(c.isspace() or ord(c)<32 for c in decoded) or any(part in ('.','..','') for part in rest.split('/')):
            raise ValueError('模型控制路径无效')
        if rest=='release':return decoded,{'name':'release_models','arguments':{}}
        match=re.fullmatch(r'(.+)/(load|unload)',rest)
        if match:return decoded,{'name':match[2]+'_model','arguments':{'model':match[1]}}
        raise ValueError('HTTP 模型控制仅支持 load、unload；内存预留或 dry_run 请使用 MCP reserve_for。')

    async def ensure_cached_png(self, file, path, allowed_root=None):
        def check(candidate, root):
            candidate=candidate.resolve()
            if not candidate.is_relative_to(root):raise ValueError('invalid PNG cache path')
            validated_png_file(str(candidate),file_identity(candidate))
            return candidate
        try:return await asyncio.to_thread(check,file,allowed_root or self.artifact_root)
        except (OSError,ValueError):pass
        match=re.fullmatch(r'/v1/files/((?:img|image)_[0-9a-f]{8,32})/([0-9]+\.png|image-[0-9]+\.png)',path)
        if not match or not self.artifact_root or not self.config.get('image_worker_port'):
            raise ImageIntegrityError('cached PNG cannot be recovered')
        target=self.artifact_root/match[1]/match[2]
        async def repair():
            try:
                if not target.resolve().is_relative_to(self.artifact_root):raise ValueError('invalid cache path')
                await asyncio.wait_for(self.cache_image_response({'data':[{'url':path}]},download_timeout=PNG_RECOVERY_DOWNLOAD_TIMEOUT,download_budget=PNG_RECOVERY_DOWNLOAD_BUDGET),PNG_RECOVERY_BRIDGE_TIMEOUT)
                if not target.resolve().is_relative_to(self.artifact_root):raise ValueError('invalid recovered cache path')
                return await asyncio.to_thread(check,target,self.artifact_root)
            except (OSError,ValueError,asyncio.TimeoutError) as error:
                raise ImageIntegrityError('cached PNG recovery failed') from error
        task=self.png_repairs.get(path)
        if task is None:
            task=asyncio.create_task(repair());self.png_repairs[path]=task
            def completed(done):
                if self.png_repairs.get(path) is done:self.png_repairs.pop(path,None)
                if not done.cancelled():done.exception()
            task.add_done_callback(completed)
        return await asyncio.shield(task)

    async def cache_image_response(self, value, download_timeout=30, download_budget=None):
        """Mirror remote PNGs before returning URLs, so sharing and restarts retain them."""
        if not self.artifact_root:
            return value
        def cache(image):
            url = image.get('url')
            if not url:
                return
            path = urllib.parse.urlsplit(url).path
            match = re.fullmatch(r'/v1/files/((?:img|image)_[0-9a-f]{8,32})/([0-9]+\.png|image-[0-9]+\.png)', path)
            if not match:
                raise ValueError('invalid remote image file URL')
            root = self.artifact_root
            target = root / match[1] / match[2]
            if not target.resolve().is_relative_to(root):
                raise ValueError('invalid image cache path')
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            try:
                deadline=time.monotonic()+download_budget if download_budget is not None else None
                with opener.open(f'http://127.0.0.1:{self.config["image_worker_port"]}'+path,timeout=download_timeout) as response:
                    length = response.headers.get('Content-Length')
                    if length is not None and (not length.isascii() or not length.isdecimal() or not 0 < int(length) <= MAX_PNG_BYTES):
                        raise ValueError('invalid remote PNG Content-Length')
                    if deadline is None:
                        data = response.read(MAX_PNG_BYTES+1)
                    else:
                        # read1 returns after one receive. A peer trickling bytes
                        # cannot retain a recovery thread beyond the total budget
                        # plus a single socket timeout.
                        data=bytearray()
                        while len(data)<=MAX_PNG_BYTES:
                            if time.monotonic()>=deadline:raise TimeoutError('PNG recovery download timed out')
                            chunk=response.read1(min(65536,MAX_PNG_BYTES+1-len(data)))
                            if not chunk:break
                            data.extend(chunk)
                    if length is not None and len(data) != int(length):
                        raise ValueError('incomplete remote PNG download')
                validate_png(data)
            except urllib.error.HTTPError as error:
                error.close()
                raise ImageIntegrityError('remote PNG download failed') from error
            except (ValueError, http.client.HTTPException) as error:
                raise ImageIntegrityError('remote PNG download failed integrity validation') from error
            target.parent.mkdir(parents=True,exist_ok=True)
            if not target.resolve().is_relative_to(root):
                raise ValueError('invalid image cache path')
            fd,name=tempfile.mkstemp(dir=target.parent,prefix='.image-cache-')
            try:
                with os.fdopen(fd,'wb') as file:
                    file.write(data);file.flush();os.fsync(file.fileno())
                os.replace(name,target)
                directory=os.open(target.parent,os.O_RDONLY|os.O_DIRECTORY)
                try:os.fsync(directory)
                finally:os.close(directory)
            finally:
                if os.path.exists(name):os.unlink(name)
            image['url']=path
        await asyncio.gather(*(asyncio.to_thread(cache,image) for image in value.get('data',[]) if isinstance(image,dict)))
        return value

    async def cache_image_rpc(self, value):
        """Retain MCP files and completed job summaries without altering inline content."""
        if not self.artifact_root or not isinstance(value, dict):
            return value
        result = value.get('result')
        if not isinstance(result, dict) or result.get('isError'):
            return value
        for content in result.get('content', []):
            if not isinstance(content, dict) or content.get('type') != 'text':
                continue
            try:
                job = json.loads(content.get('text', ''))
            except (ValueError, TypeError):
                continue
            if not isinstance(job, dict) or job.get('status') != 'completed' or not re.fullmatch(r'(?:img|image)_[0-9a-f]{8,32}', str(job.get('id', ''))):
                continue
            files = job.get('files', [])
            if not isinstance(files, list) or not files or any(not isinstance(url, str) for url in files):
                raise ValueError('invalid completed image job files')
            images = [{'url': url} for url in files]
            if any(not urllib.parse.urlsplit(image['url']).path.startswith('/v1/files/'+job['id']+'/') for image in images):
                raise ValueError('image job and files differ')
            await self.cache_image_response({'data': images})
            saved = dict(job, files=[image['url'] for image in images], urls=[image['url'] for image in images])
            target = self.artifact_root / job['id'] / '.jarvis-job.json'
            if not target.resolve().is_relative_to(self.artifact_root):
                raise ValueError('invalid cached job path')
            fd, name = tempfile.mkstemp(dir=target.parent, prefix='.job-cache-')
            try:
                with os.fdopen(fd, 'wb') as file:
                    file.write(json.dumps(saved, ensure_ascii=False).encode()); file.flush(); os.fsync(file.fileno())
                os.replace(name, target)
                directory = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
                try: os.fsync(directory)
                finally: os.close(directory)
            finally:
                if os.path.exists(name): os.unlink(name)
        return value

    def cached_image_job(self, job_id):
        if not self.artifact_root or not re.fullmatch(r'(?:img|image)_[0-9a-f]{8,32}', job_id):
            return None
        target = self.artifact_root / job_id / '.jarvis-job.json'
        if not target.resolve().is_relative_to(self.artifact_root):
            return None
        try:
            saved = json.loads(target.read_text())
            if saved.get('id') != job_id or saved.get('status') != 'completed' or not saved.get('urls'):
                return None
            for url in saved['urls']:
                match = re.fullmatch(r'/v1/files/('+re.escape(job_id)+r')/([0-9]+\.png|image-[0-9]+\.png)', url)
                if not match: return None
                file = self.artifact_root / match[1] / match[2]
                if not file.resolve().is_relative_to(self.artifact_root) or not file.is_file(): return None
                validated_png_file(str(file), file_identity(file))
            return saved
        except (OSError, ValueError, TypeError, AttributeError):
            return None

    @staticmethod
    def image_job_rpc(job, ident):
        content = [{'type':'text','text':json.dumps(job, ensure_ascii=False)}]
        for url in job['urls']:
            content.append({'type':'resource_link','uri':url,'name':Path(urllib.parse.urlsplit(url).path).name,'mimeType':'image/png'})
        return {'jsonrpc':'2.0','id':ident,'result':{'isError':False,'content':content}}

    async def request_payload(self, reader, headers):
        limit = 32 * 1024 * 1024
        if b'transfer-encoding' not in headers:
            size = int(headers.get(b'content-length', b'0'))
            if not 0 <= size <= limit:
                raise ValueError('request is too large')
            return await asyncio.wait_for(reader.readexactly(size), 60)
        if headers[b'transfer-encoding'].lower() != b'chunked' or b'content-length' in headers:
            raise ValueError('invalid request framing')
        chunks, total = bytearray(), 0
        deadline = asyncio.get_running_loop().time() + 60
        async def read(awaitable):
            return await asyncio.wait_for(awaitable, max(0, deadline - asyncio.get_running_loop().time()))
        while True:
            line = await read(reader.readuntil(b'\r\n'))
            if len(line) > 8192:
                raise ValueError('chunk header is too large')
            size = int(line.split(b';', 1)[0].strip(), 16)
            if size < 0 or total + size > limit:
                raise ValueError('request is too large')
            if size == 0:
                trailers = 0
                while True:
                    line = await read(reader.readuntil(b'\r\n'))
                    trailers += len(line)
                    if trailers > 8192:
                        raise ValueError('trailers are too large')
                    if line == b'\r\n':
                        return bytes(chunks)
            data = await read(reader.readexactly(size + 2))
            if data[-2:] != b'\r\n':
                raise ValueError('invalid chunk')
            chunks.extend(data[:-2]); total += size

    async def completion_payload(self, reader, head):
        fields={}
        for line in head.split(b'\r\n')[1:]:
            if not line:continue
            key,sep,value=line.partition(b':')
            if not sep:raise ValueError('聊天响应头格式错误')
            key=key.lower()
            if key in fields and key in (b'content-length',b'transfer-encoding'):
                raise ValueError('聊天响应长度不明确')
            fields[key]=value.strip()
        async with asyncio.timeout(180):
            if b'content-length' in fields or b'transfer-encoding' in fields:
                data=await self.request_payload(reader,fields)
            else:
                data=bytearray()
                while chunk:=await reader.read(65536):
                    data.extend(chunk)
                    if len(data)>32*1024*1024:raise ValueError('聊天回复过大')
            return json.loads(data)

    async def local_rpc(self, port, value, timeout=15):
        return await request_json(f'http://127.0.0.1:{port}/mcp',method='POST',body=json.dumps(value).encode(),
            headers={'Content-Type':'application/json'},timeout=timeout,max_bytes=96*1024*1024)

    def unavailable_video(self, models):
        videos = [m for m in models if m.get('kind') == 'video']
        if not videos:
            videos = [{'id': 'minimax-h3', 'name': 'MiniMax H3', 'kind': 'video', 'keep_loaded': False}]
        return [dict(m, machine=self.config['video_worker_machine'], state='unknown', running=None,
                     resident_bytes=None, working_bytes=None, last_error='视频服务器状态暂不可查询') for m in videos]

    @staticmethod
    def worker_videos(models):
        if not isinstance(models, list) or any(not isinstance(m, dict) for m in models):
            raise ValueError('invalid worker model list')
        videos = [m for m in models if m.get('kind') == 'video']
        if not videos:
            raise ValueError('worker does not offer video')
        return videos

    def unavailable_image(self, models):
        images = [m for m in models if m.get('kind') == 'image']
        if not images:
            images = [{'id':'qwen-image-2.1-turbo','name':'Qwen-Image 2.1 Turbo','kind':'image'}]
        return [dict(m, machine=self.config['image_worker_machine'], state='unknown', running=None,
                     resident_bytes=None, working_bytes=None, last_error='图片服务器状态暂不可查询') for m in images]

    def worker_images(self, models):
        if not isinstance(models, list) or any(not isinstance(m, dict) for m in models):
            raise ValueError('invalid image worker model list')
        images = [dict(m, machine=self.config['image_worker_machine']) for m in models if m.get('kind') == 'image']
        if not images:
            raise ValueError('worker does not offer images')
        return images

    async def model_list(self, value):
        independent_voice=any(port and port!=self.backend for port in (self.config.get('speech_backend_port'),self.config.get('transcription_backend_port')))
        modern=bool(self.config.get('image_worker_port') or independent_voice)
        rpc_ports=list(dict.fromkeys([self.backend]+[self.config[k] for k in ('video_worker_port','image_worker_port') if self.config.get(k)]+([self.config['speech_backend_port']] if modern and self.config.get('speech_backend_port') else [])))
        queries={('rpc',port):self.local_rpc(port,value,timeout=STATUS_QUERY_TIMEOUT if port==self.backend else 1.5) for port in rpc_ports}
        if modern:
            queries[('brain',None)]=self.fetch_json(True,'/models',timeout=STATUS_QUERY_TIMEOUT)
            for port in dict.fromkeys(self.config[k] for k in ('speech_backend_port','transcription_backend_port') if self.config.get(k)):
                queries[('tools',port)]=self.fetch_json(False,'/tools',port,timeout=1.5)
        replies=await collect_status_queries(queries)
        result = status_result(replies,('rpc',self.backend))
        text = result['result']['content'][0]
        state = json.loads(text['text'])
        if not modern:
            # Preserve the legacy separate-video topology and its roster order.
            if not self.config.get('video_worker_port'):return result
            try:
                remote=status_result(replies,('rpc',self.config['video_worker_port']))
                worker=json.loads(remote['result']['content'][0]['text'])
                videos=[dict(t,machine=self.config['video_worker_machine']) for t in self.worker_videos(worker['models'])]
                state['video_worker_memory']=worker.get('memory')
            except (OSError,ValueError,KeyError,TypeError,IndexError):
                videos=self.unavailable_video(state['models'])
            state['models']=[m for m in state['models'] if m.get('kind')!='video']+videos
            text['text']=json.dumps(state,ensure_ascii=False)
            return result
        if not isinstance(state.get('memory'),dict):state['memory']={}
        # The head's own MCP roster can contain stale proxy models (including
        # Whisper). Replace each role with the endpoint actually serving it.
        async def endpoint_models(port):
            reply = status_result(replies,('tools',port))
            models = reply.get('data')
            if not isinstance(models, list) or any(not isinstance(m,dict) or not isinstance(m.get('id'),str) or not m['id'] or not isinstance(m.get('kind'),str) or not m['kind'] for m in models):raise ValueError('invalid service model list')
            return models
        async def remote_brain():
            reply = status_result(replies,('brain',None))
            actual = next((m for m in reply.get('data', []) if m.get('id') == self.config['model']), None)
            if actual is None:raise ValueError('configured chat model unavailable')
            state,ready=remote_chat_state(actual)
            return {'id':self.config['model'],'name':self.config['name'],'kind':'chat',
                    'machine':self.base.hostname,'state':state,'running':ready}
        roles=[('speech',self.config.get('speech_backend_port')),('transcription',self.config.get('transcription_backend_port'))]
        jobs=[remote_brain()]+[endpoint_models(port) for _,port in roles if port]
        results=await asyncio.gather(*jobs,return_exceptions=True)
        brain=results[0]
        if isinstance(brain,BaseException):brain={'id':self.config['model'],'name':self.config['name'],'kind':'chat','machine':self.base.hostname,'state':'unavailable','running':None,'last_error':'聊天模型状态无法查询'}
        state['models']=[brain if m.get('kind')=='chat' else m for m in state['models']]
        if not any(m.get('kind')=='chat' for m in state['models']):state['models'].insert(0,brain)
        n=1
        for kind,port in roles:
            if not port:continue
            service=results[n];n+=1
            found=[] if isinstance(service,BaseException) else [dict(m,machine='head',running=True if m.get('state') in ('ready','busy') else False if m.get('state') in ('unloaded','failed') else None) for m in service if m.get('kind')==kind]
            if not found:found=[{'id':kind+'-unavailable','kind':kind,'machine':'head','state':'unavailable','running':None,'last_error':'服务状态无法查询'}]
            state['models']=[m for m in state['models'] if m.get('kind')!=kind]+found
        speech_port=self.config.get('speech_backend_port')
        state['voice_coordinator_memory']=state.get('memory') if not speech_port or speech_port==self.backend else None
        if speech_port and speech_port!=self.backend:
            # The head's pause bit describes its own voice loop, not 8194.
            try:
                actual_voice=status_result(replies,('rpc',speech_port))
                actual_voice=json.loads(actual_voice['result']['content'][0]['text'])
                voice_memory=actual_voice.get('memory')
                if not isinstance(voice_memory,dict):raise ValueError('invalid voice memory')
                state['voice_coordinator_memory']=dict(voice_memory)
                paused=voice_memory.get('voice_paused')
                state.setdefault('memory',{})['voice_paused']=paused if type(paused) is bool else None
            except (OSError,ValueError,KeyError,TypeError,IndexError,AttributeError):state.setdefault('memory',{})['voice_paused']=None
        workers={}
        async def worker_models(port):
            if port not in workers:
                try:
                    remote=status_result(replies,('rpc',port))
                    workers[port]=json.loads(remote['result']['content'][0]['text'])
                except (OSError,ValueError,KeyError,TypeError,IndexError):workers[port]=None
            if workers[port] is None:raise ValueError('worker unavailable')
            return workers[port]
        if self.config.get('video_worker_port'):
            try:
                worker = await worker_models(self.config['video_worker_port'])
                videos = [dict(t, machine=self.config['video_worker_machine']) for t in self.worker_videos(worker['models'])]
                state['video_worker_memory'] = worker.get('memory')
            except (OSError, ValueError, KeyError, TypeError, IndexError):
                videos = self.unavailable_video(state['models'])
            state['models'] = [t for t in state['models'] if t.get('kind') != 'video'] + videos
        if self.config.get('image_worker_port'):
            try:
                worker = await worker_models(self.config['image_worker_port'])
                images = self.worker_images(worker['models'])
                state['image_worker_memory'] = worker.get('memory')
            except (OSError, ValueError, KeyError, TypeError, IndexError):
                images = self.unavailable_image(state['models'])
            state['models'] = [m for m in state['models'] if m.get('kind') != 'image'] + images
        text['text'] = json.dumps(state, ensure_ascii=False)
        return result

    async def metadata(self, path):
        ports=list(dict.fromkeys(self.config[k] for k in ('speech_backend_port','transcription_backend_port','video_worker_port','image_worker_port') if self.config.get(k) and self.config[k]!=self.backend))
        queries={('local',self.backend):self.fetch_json(False,path,timeout=STATUS_QUERY_TIMEOUT),('brain',None):self.fetch_json(True,'/models',timeout=STATUS_QUERY_TIMEOUT)}
        for port in ports:queries[('local',port)]=self.fetch_json(False,path,port,timeout=1.5)
        replies=await collect_status_queries(queries)
        local=status_result(replies,('local',self.backend));remote=status_result(replies,('brain',None))
        actual = next((m for m in remote.get('data', []) if m.get('id') == self.config['model']), None)
        if actual is None:
            raise ConnectionError('configured upstream model is unavailable')
        state,ready=remote_chat_state(actual)
        context = actual.get('meta', {}).get('n_ctx') or self.config.get('effective_context')
        if path == '/models':
            brain = dict(actual, name=self.config['name'], kind='chat', machine=self.base.hostname,
                         state=state, running=ready, capabilities=['chat_completion'], default_for=['chat_completion'],
                         qualified=True)
            brain['jarvis'] = {'default_reasoning_effort': 'high', 'reasoning_efforts': sorted(EFFORTS),
                               'effective_context': context,
                               'voice_effort_models': {e: self.config['model'] + '--jarvis-' + e for e in EFFORTS},
                               'image_input': 'image' in actual.get('architecture', {}).get('input_modalities', []),
                               'pdf_text': Path('/usr/bin/pdftotext').exists()}
        else:
            brain = {'id': self.config['model'], 'name': self.config['name'], 'kind': 'chat',
                     'state':state, 'running':ready, 'machine': self.base.hostname,
                     'keep_loaded': True, 'resident_bytes': 0, 'working_bytes': 0}
        others = [dict(m) for m in local.get('data', []) if m.get('kind') != 'chat']
        if self.config.get('speech_backend_port'):
            speech = status_result(replies,('local',self.config['speech_backend_port']))
            speakers = [describe_voices(dict(m), self.config.get('voice_catalog'))
                        for m in speech.get('data', []) if m.get('kind') == 'speech']
            if not speakers:
                raise ConnectionError('configured speech service has no speech model')
            others = [m for m in others if m.get('kind') != 'speech'] + speakers
        if self.config.get('transcription_backend_port'):
            recognition = status_result(replies,('local',self.config['transcription_backend_port']))
            recognizers = [dict(m, machine='head') for m in recognition.get('data', []) if m.get('kind') == 'transcription']
            if not recognizers:
                raise ConnectionError('configured transcription service has no transcription model')
            others = [m for m in others if m.get('kind') != 'transcription'] + recognizers
        if self.config.get('video_worker_port'):
            try:
                worker = status_result(replies,('local',self.config['video_worker_port']))
                videos = [dict(m, machine=self.config['video_worker_machine']) for m in self.worker_videos(worker.get('data', []))]
            except (OSError, ValueError, TypeError, AttributeError):
                videos = self.unavailable_video(others)
            others = [m for m in others if m.get('kind') != 'video'] + videos
        if self.config.get('image_worker_port'):
            try:
                worker = status_result(replies,('local',self.config['image_worker_port']))
                images = self.worker_images(worker.get('data', []))
            except (OSError, ValueError, TypeError, AttributeError):
                images = self.unavailable_image(others)
            others = [m for m in others if m.get('kind') != 'image'] + images
        if path == '/models':
            for model in others:
                limits_key = {'image': 'image_limits', 'video': 'video_limits'}.get(model.get('kind'))
                if limits_key and model.get('id') in self.config.get(limits_key, {}):
                    model['limits'] = self.config[limits_key][model['id']]
        return dict(local, data=[brain] + others)

    async def pdf_text(self, payload):
        if not payload.startswith(b'%PDF-'):
            raise ValueError('文件不是有效的PDF')
        def limits():
            resource.setrlimit(resource.RLIMIT_AS, (128 * 1024 * 1024,) * 2)
            resource.setrlimit(resource.RLIMIT_CPU, (10, 10))
        process = await asyncio.create_subprocess_exec(
            '/usr/bin/pdftotext', '-layout', '-enc', 'UTF-8', '-', '-',
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, preexec_fn=limits)
        async def feed():
            try:
                process.stdin.write(payload)
                await process.stdin.drain()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                process.stdin.close()
        async def read():
            chunks = []; size = 0
            while chunk := await process.stdout.read(65536):
                size += len(chunk)
                if size > 512 * 1024:
                    raise ValueError('PDF文字过多，请拆分文件后上传')
                chunks.append(chunk)
            return b''.join(chunks)
        tasks = [asyncio.create_task(feed()), asyncio.create_task(read()), asyncio.create_task(process.wait())]
        try:
            _, output, code = await asyncio.wait_for(asyncio.gather(*tasks), 15)
            if code:
                raise ValueError('PDF读取失败，请确认文件未加密且未损坏')
            text = output.decode('utf-8').strip()
            if not text:
                raise ValueError('PDF未提取到文字；扫描件请改传图片')
            return text
        except asyncio.TimeoutError:
            raise ValueError('处理PDF超时，请拆分后重试')
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            if process.returncode is None:
                process.kill()
            await process.wait()

    async def reply(self, writer, status, value):
        value=normalize_mcp_files(value)
        body = await asyncio.to_thread(lambda:json.dumps(value, ensure_ascii=False).encode())
        reason = {200: 'OK', 400: 'Bad Request', 403: 'Forbidden', 404: 'Not Found', 405: 'Method Not Allowed', 413: 'Payload Too Large', 503: 'Service Unavailable'}.get(status, 'Error')
        writer.write(f'HTTP/1.1 {status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode() + body)
        await writer.drain()

    async def client(self, reader, writer):
        upstream = None
        tasks = []
        response_started = False
        mcp_chat_request = None
        mcp_ident = None
        try:
            head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
            first, *fields = head[:-4].split(b'\r\n')
            method, target, _ = first.decode('ascii').split(' ', 2)
            path = urllib.parse.urlsplit(target).path
            headers = {}
            for field in fields:
                key, sep, value = field.partition(b':')
                if not sep:
                    raise ValueError('invalid header')
                key = key.lower()
                if key in headers and key in (b'content-length', b'transfer-encoding'):
                    raise ValueError('duplicate framing header')
                headers[key] = value.strip()
            if method in ('GET', 'HEAD') and self.artifact_root:
                parts = path.split('/')
                if method == 'GET' and len(parts) == 4 and parts[1:3] in (['v1','jobs'], ['v1','videos']):
                    section = 'jobs' if parts[2] == 'jobs' else 'videos'
                    saved = await asyncio.to_thread(self.cached_image_job, parts[3]) or self.history.get(section, {}).get(parts[3])
                    if saved:
                        await self.reply(writer, 200, saved)
                        return
                saved_file = None
                if len(parts) == 5 and parts[1:3] == ['v1','files']:
                    job = self.history.get('jobs', {}).get(parts[3], {})
                    archived = path in job.get('urls', []) and job.get('status') == 'completed'
                    generated = re.fullmatch(r'(?:img|image|video)_[0-9a-f]{8,32}', parts[3]) and re.fullmatch(r'(?:[0-9]+\.png|image-[0-9]+\.png|video\.mp4)', parts[4])
                    if archived or generated:
                        saved_file = self.artifact_root / parts[3] / parts[4]
                if len(parts) == 5 and parts[1:3] == ['v1','videos'] and parts[4] == 'content':
                    job = self.history.get('jobs', {}).get(parts[3], {})
                    if job.get('status') == 'completed' or re.fullmatch(r'video_[0-9a-f]{16}', parts[3]):
                        saved_file = self.artifact_root / parts[3] / 'video.mp4'
                allowed_root = self.artifact_root
                if saved_file and not saved_file.is_file() and parts[3].startswith(('video_', 'img_', 'image_')):
                    for root in self.config.get('legacy_video_roots', []):
                        root = Path(root).resolve()
                        candidate = root / parts[3] / saved_file.name
                        if candidate.resolve().is_relative_to(root) and candidate.is_file():
                            saved_file, allowed_root = candidate, root
                            break
                if saved_file and saved_file.resolve().is_relative_to(allowed_root) and saved_file.is_file():
                    if saved_file.suffix.lower()=='.png':
                        saved_file=await self.ensure_cached_png(saved_file,path,allowed_root)
                    mime = mimetypes.guess_type(saved_file.name)[0] or 'application/octet-stream'
                    size = saved_file.stat().st_size
                    writer.write(f'HTTP/1.1 200 OK\r\nContent-Type: {mime}\r\nContent-Length: {size}\r\nCache-Control: private, no-store\r\nConnection: close\r\n\r\n'.encode())
                    response_started = True
                    if method == 'HEAD':
                        await writer.drain()
                        return
                    with saved_file.open('rb') as file:
                        while chunk := await asyncio.to_thread(file.read,65536):
                            writer.write(chunk)
                            await writer.drain()
                    return
            if method == 'GET' and path.startswith('/v1/voice-previews/'):
                match = re.fullmatch(r'/v1/voice-previews/([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.wav', path)
                audio = preview_audio(self.config.get('voice_catalog'), match[1]) if match else None
                if audio is None:
                    await self.reply(writer, 404, {'error': {'message': 'voice preview not found'}})
                    return
                writer.write(f'HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {len(audio)}\r\nCache-Control: private, max-age=3600\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n'.encode() + audio)
                response_started = True
                await writer.drain()
                return
            if method == 'GET' and path in ('/v1/models', '/v1/tools'):
                await self.reply(writer, 200, await self.metadata(path[3:]))
                return
            if method == 'GET' and path == '/__jarvis_brain/status':
                await self.reply(writer, 200, {'model': self.config['model'], 'default_effort': 'high', 'recent': list(self.recent)})
                return
            if method == 'POST' and path == '/v1/jarvis/extract-pdf':
                if b'transfer-encoding' in headers:
                    raise ValueError('PDF requests require Content-Length')
                size = int(headers.get(b'content-length', b'0'))
                if not 0 < size <= 10 * 1024 * 1024:
                    await self.reply(writer, 413, {'error': {'message': 'PDF最大10MB'}})
                    return
                payload = await asyncio.wait_for(reader.readexactly(size), 30)
                text = await self.pdf_text(payload)
                await self.reply(writer, 200, {'text': text})
                return
            payload = None
            control=self.http_model_control(path)
            if control is not None:
                if method!='POST':
                    await self.reply(writer,405,{'error':{'message':'模型控制必须使用 POST'}});return
                normalized,params=control
                refusal=await self.model_control_refusal(params)
                if refusal:
                    await self.reply(writer,403,{'error':{'message':refusal}});return
                payload=await self.request_payload(reader,headers)
                if urllib.parse.urlsplit(target).query or (payload.strip() and json.loads(payload)!={}):
                    raise ValueError('HTTP 模型控制不支持请求参数；需要 dry_run、hold_s 或内存预留时请使用 MCP。')
                path=normalized
                first=f'{method} {normalized} HTTP/1.1'.encode()
            ports = self.video_ports(path, method)
            if method == 'POST' and path == '/v1/videos':
                media_type = headers.get(b'content-type', b'application/json').split(b';', 1)[0].strip().lower()
                if media_type != b'application/json':
                    raise ValueError('视频长度防护当前要求 application/json 请求格式')
                payload = await self.request_payload(reader, headers)
                video_body = json.loads(payload)
                if not isinstance(video_body, dict):
                    raise ValueError('视频参数必须为对象')
                video_body['prompt'] = await asyncio.to_thread(prepare_video_prompt, video_body.get('prompt', ''))
                payload = json.dumps(video_body).encode()
            managed = self.config.get('video_worker_port') or self.config.get('image_worker_port') or self.config.get('speech_backend_port') or self.config.get('transcription_backend_port')
            if managed and method == 'GET' and path == '/v1/skills/model-manager':
                value = await self.fetch_json(False, '/skills/model-manager')
                if self.config.get('image_worker_port') or self.config.get('speech_backend_port') or self.config.get('transcription_backend_port'):
                    value['text'] = model_guidance(self.config) + '\n只在用户要求管理模型或任务内存不足时调用模型管理工具。不得卸载聊天模型；不要为媒体任务卸载语音或听写服务。'
                else:
                    value['text'] = '视频运行在独立设备；不要为视频卸载主机语音或图片模型。\n' + value.get('text', '')
                await self.reply(writer, 200, value)
                return
            if method == 'POST' and path == '/mcp':
                payload = await self.request_payload(reader, headers)
                value = json.loads(payload)
                params = value.get('params') if isinstance(value, dict) else None
                if isinstance(params,dict) and value.get('method')=='tools/call':
                    try:normalize_job_arguments(params)
                    except ValueError as error:
                        await self.reply(writer,200,mcp_text_result(value.get('id'),str(error),True));return
                    payload=json.dumps(value).encode()
                if isinstance(params,dict) and value.get('method') == 'tools/call' and params.get('name') == 'chat':
                    mcp_ident=value.get('id')
                    try:mcp_chat_request=mcp_chat_body(params.get('arguments'))
                    except ValueError as error:
                        await self.reply(writer,200,mcp_text_result(mcp_ident,str(error),True))
                        return
                if self.config.get('video_worker_port') and isinstance(params, dict) and value.get('method') == 'tools/call' and params.get('name') == 'generate_video':
                    video_args = params.get('arguments')
                    if not isinstance(video_args, dict):
                        raise ValueError('视频参数必须为对象')
                    try:
                        video_args['prompt'] = await asyncio.to_thread(prepare_video_prompt, video_args.get('prompt', ''))
                    except ValueError as error:
                        await self.reply(writer, 200, {'jsonrpc': '2.0', 'id': value.get('id'), 'result': {
                            'isError': True, 'content': [{'type': 'text', 'text': str(error)}]}})
                        return
                    payload = json.dumps(value).encode()
                if isinstance(params, dict) and value.get('method') == 'tools/call' and params.get('name') == 'list_models':
                    await self.reply(writer, 200, await self.model_list(value))
                    return
                if isinstance(params,dict) and value.get('method') == 'tools/call':
                    refusal=await self.prepare_audio_tool(params) or await self.model_control_refusal(params)
                    if refusal:
                        await self.reply(writer,200,{'jsonrpc':'2.0','id':value.get('id'),'result':{'isError':True,'content':[{'type':'text','text':refusal}]}})
                        return
                    payload = json.dumps(value).encode()
                ports = self.mcp_ports(value)
                args = (params.get('arguments') or {}) if isinstance(params, dict) else {}
                job_id = str(args.get('id', args.get('job_id', ''))) if isinstance(args, dict) else ''
                video_job=bool(self.config.get('video_worker_port') and job_id.startswith('video_'))
                image_job=bool(self.config.get('image_worker_port') and job_id.startswith(('img_', 'image_')))
                audio_port = self.audio_job_port(job_id)
                if isinstance(params, dict) and value.get('method') == 'tools/call' and params.get('name') in ('get_job', 'cancel_job') and (video_job or image_job or audio_port):
                    cached_image = await asyncio.to_thread(self.cached_image_job, job_id)
                    saved = cached_image or self.history.get('jobs', {}).get(job_id)
                    if cached_image and params['name'] == 'get_job':
                        await self.reply(writer, 200, self.image_job_rpc(cached_image, value.get('id')))
                        return
                    if saved and params['name'] == 'get_job':
                        await self.reply(writer, 200, {'jsonrpc':'2.0','id':value.get('id'),'result':{'content':[{'type':'text','text':json.dumps(saved)}],'isError':saved.get('status')=='failed'}})
                        return
                    probe = dict(value, params=dict(params, name='get_job', arguments={'id': job_id, 'wait_s': 0}))
                    candidates = ([audio_port, self.backend] if audio_port else [self.config['video_backend_port'], self.config['video_worker_port'], self.backend] if job_id.startswith('video_') else [self.config['image_worker_port'], self.backend])
                    owner=None
                    for port in dict.fromkeys(candidates):
                        try:
                            found = await self.local_rpc(port, probe, timeout=1.5)
                        except (OSError, ValueError):
                            continue
                        if self.rpc_job_summary(found,job_id) is not None:
                            owner=port
                            ports = [port]
                            if params['name'] == 'get_job' and not args.get('wait_s'):
                                if port == self.config.get('image_worker_port') and job_id.startswith(('img_', 'image_')):
                                    found = await self.cache_image_rpc(found)
                                await self.reply(writer, 200, found)
                                return
                            break
                    if params['name']=='cancel_job' and owner is None:
                        await self.reply(writer,200,{'jsonrpc':'2.0','id':value.get('id'),'result':{'isError':True,'content':[{'type':'text','text':'无法确认任务所属服务，未发送取消操作；请稍后重新查询任务状态。'}]}})
                        return
            # Preparation/probing may take seconds. Never submit a consumed request
            # whose caller disconnected while we were waiting.
            if payload is not None and reader.at_eof():
                return
            if payload is None and ports != [self.backend] and method in ('POST', 'PUT', 'PATCH'):
                payload = await self.request_payload(reader, headers)
            if payload is not None:
                clean = [f for f in fields if f.split(b':', 1)[0].lower() not in (b'content-length', b'transfer-encoding')]
                head = first + b'\r\n' + b'\r\n'.join(clean) + f'\r\nContent-Length: {len(payload)}\r\n\r\n'.encode()
            if method == 'POST' and (path == '/v1/chat/completions' or mcp_chat_request is not None):
                if mcp_chat_request is not None:
                    raw_value=mcp_chat_request
                else:
                    if b'transfer-encoding' in headers:
                        raise ValueError('chat requests require Content-Length')
                    size = int(headers.get(b'content-length', b'0'))
                    if size < 0 or size > 32 * 1024 * 1024:
                        await self.reply(writer, 413, {'error': {'message': '请求附件累计过大，请减少附件或新建会话'}})
                        return
                    body = await asyncio.wait_for(reader.readexactly(size), 60)
                    raw_value = json.loads(body)
                if not isinstance(raw_value,dict):raise ValueError('request must be a JSON object')
                voice = is_voice(raw_value, self.config)
                value = chat_body(raw_value, self.config)
                if (self.config.get('image_worker_port') or self.config.get('speech_backend_port') or self.config.get('transcription_backend_port')) and model_status_requested(raw_value):
                    rpc={'jsonrpc':'2.0','id':'jarvis-model-status','method':'tools/call','params':{'name':'list_models','arguments':{}}}
                    try:
                        roster=await self.model_list(rpc)
                        snapshot=json.loads(roster['result']['content'][0]['text'])
                        facts=chinese_status_facts(snapshot)
                        context='以下是本次请求时模型状态的实时查询快照；仅按快照回答，状态可能随后变化。内存按设备区分，不可混为同一台机器：'+json.dumps(facts,ensure_ascii=False)
                    except (OSError,ValueError,KeyError,TypeError,IndexError,AttributeError,asyncio.TimeoutError):
                        context='本次模型状态查询失败；请明确说明无法确认，不能猜测模型或状态。'
                    value['messages'].insert(0,{'role':'system','content':context})
                if reader.at_eof():return
                encoded = json.dumps(value, ensure_ascii=False).encode()
                remote_port = self.base.port or (443 if self.base.scheme == 'https' else 80)
                tls = ssl.create_default_context() if self.base.scheme == 'https' else None
                back, upstream = await asyncio.wait_for(asyncio.open_connection(self.base.hostname, remote_port, ssl=tls), 10)
                if reader.at_eof():return
                route = self.base.path.rstrip('/') + '/chat/completions'
                auth = self.config['api_key']
                remote_headers = (f'POST {route} HTTP/1.1\r\nHost: {self.base.netloc}\r\nAuthorization: Bearer {auth}\r\nContent-Type: application/json\r\nContent-Length: {len(encoded)}\r\nConnection: close\r\n\r\n').encode()
                upstream.write(remote_headers + encoded)
                await upstream.drain()
                entry = {'time': round(time.time()), 'effort': value['reasoning_effort'],
                         'stream': bool(value.get('stream')), 'max_tokens': value.get('max_tokens'), 'status': 'active', 'voice_output_policy': voice}
                self.recent.append(entry)
                async def downstream():
                    nonlocal response_started, back, upstream
                    for attempt in range(2):
                        entry['attempts'] = attempt + 1
                        response = await asyncio.wait_for(back.readuntil(b'\r\n\r\n'), 60)
                        entry['http_status'] = int(response.split(b' ', 2)[1])
                        if mcp_chat_request is not None:
                            if entry['http_status'] != 200:
                                result=mcp_text_result(mcp_ident,'远端聊天服务暂不可用，请稍后重试',True)
                            else:
                                completion=await self.completion_payload(back,response)
                                result=mcp_chat_result(mcp_ident,completion,value,voice)
                            await self.reply(writer,200,result)
                            response_started=True;entry['status']='upstream_closed'
                            return
                        if entry['http_status'] in (401, 403):
                            await self.reply(writer, 503, {'error': {'message': '远端大模型鉴权失败，请检查服务端接入配置'}})
                            response_started = True
                            entry['status'] = 'upstream_auth_failed'
                            return
                        if not value.get('stream') or entry['http_status'] != 200:
                            writer.write(response)
                            response_started = True
                            await writer.drain()
                            await relay(back, writer)
                            entry['status'] = 'upstream_closed'
                            return
                        response_headers = {k.lower(): v.strip() for k, v in
                                            (line.split(b':', 1) for line in response.split(b'\r\n')[1:] if b':' in line)}
                        async def publish(data):
                            nonlocal response_started
                            if not response_started:
                                writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n')
                                response_started = True
                            writer.write(data)
                            await writer.drain()
                        entry['_started'] = time.monotonic()
                        try:
                            complete = await guarded_stream(back, response_headers, publish, entry, VoiceStream(value) if voice else None)
                        except (OSError, ValueError, asyncio.TimeoutError, asyncio.IncompleteReadError):
                            entry['status'] = 'stream_failed'
                            if response_started:
                                writer.write(b'data: {"error":{"message":"Chat stream incomplete; please retry"}}\n\n')
                                await writer.drain()
                            raise
                        if complete:
                            entry.pop('_started', None)
                            entry['status'] = 'upstream_closed'
                            return
                        entry.pop('_started', None)
                        entry['status'] = 'empty_reply'
                        if attempt:
                            await self.reply(writer, 503, {'error': {'message': '大模型连续返回空回复，请重试'}})
                            response_started = True
                            return
                        upstream.close()
                        await upstream.wait_closed()
                        retry = dict(value)
                        retry['messages'] = [*value['messages'], {'role': 'system', 'content':
                            ('上一轮没有可朗读的最终答复。请用用户当前语言直接给出简短答复，中文使用简体，不要输出思考、内部指令或网址。已经完成的工具任务只确认结果，不得再次执行。' if voice else
                             'The previous generation produced no visible answer or tool call. Answer the last user request with a nonempty visible reply, or call the appropriate available tool.')}]
                        retry_encoded = json.dumps(retry, ensure_ascii=False).encode()
                        back, upstream = await asyncio.wait_for(asyncio.open_connection(self.base.hostname, remote_port, ssl=tls), 10)
                        if reader.at_eof():return
                        retry_headers = (f'POST {route} HTTP/1.1\r\nHost: {self.base.netloc}\r\nAuthorization: Bearer {auth}\r\nContent-Type: application/json\r\nContent-Length: {len(retry_encoded)}\r\nConnection: close\r\n\r\n').encode()
                        upstream.write(retry_headers + retry_encoded)
                        await upstream.drain()
                async def disconnected():
                    await reader.read(1)
                    entry['status'] = 'client_disconnected'
                tasks = [asyncio.create_task(downstream()), asyncio.create_task(disconnected())]
            elif ports != [self.backend] or payload is not None:
                async def routed():
                    nonlocal upstream, response_started
                    for index, port in enumerate(ports):
                        retry_read = method in ('GET', 'HEAD') and index + 1 < len(ports)
                        try:
                            back, upstream = await asyncio.wait_for(asyncio.open_connection('127.0.0.1', port), 3 if retry_read else 10)
                            if reader.at_eof():return
                            upstream.write(head + (payload or b'')); await upstream.drain()
                            response = await asyncio.wait_for(back.readuntil(b'\r\n\r\n'), 3 if retry_read else 3600)
                        except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError):
                            if upstream:
                                upstream.close()
                                try:await upstream.wait_closed()
                                except OSError:pass
                                upstream = None
                            if retry_read:continue
                            raise
                        code = int(response.split(b' ', 2)[1])
                        if (code == 404 and index + 1 < len(ports)) or (retry_read and code in (502, 503, 504)):
                            upstream.close(); await upstream.wait_closed(); upstream = None
                            continue
                        image_rpc = path == '/mcp' and isinstance(params, dict) and (params.get('name') == 'generate_image' or params.get('name') == 'get_job' and job_id.startswith(('img_', 'image_')))
                        file_rpc = path == '/mcp' and isinstance(params,dict) and params.get('name') in ('generate_image','generate_video','synthesize_speech','transcribe_audio','get_job','cancel_job')
                        if code == 200 and file_rpc:
                            result = await read_json_response(back,response,timeout=3600,max_bytes=96*1024*1024)
                            if image_rpc and port == self.config.get('image_worker_port'):
                                result = await self.cache_image_rpc(result)
                            await self.reply(writer,200,result);response_started=True
                            return
                        if port == self.config.get('image_worker_port') and code == 200 and path == '/v1/images/generations':
                            fields = dict(line.split(b':',1) for line in response.split(b'\r\n')[1:] if b':' in line)
                            length = next((v.strip() for k,v in fields.items() if k.lower()==b'content-length'),b'')
                            limit = 2*1024*1024
                            if length.isdigit() and int(length)<=limit:
                                value = json.loads(await back.readexactly(int(length)))
                                value = await self.cache_image_response(value)
                                await self.reply(writer,200,value);response_started=True
                                return
                        writer.write(response); response_started = True; await writer.drain()
                        await relay(back, writer)
                        return
                async def disconnected():
                    await reader.read(1)
                tasks = [asyncio.create_task(routed()), asyncio.create_task(disconnected())]
            else:
                back, upstream = await asyncio.wait_for(asyncio.open_connection('127.0.0.1', self.backend), 10)
                upstream.write(head)
                await upstream.drain()
                response_started = True
                tasks = [asyncio.create_task(relay(reader, upstream)), asyncio.create_task(relay(back, writer))]
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except ImageIntegrityError:
            if not response_started:
                await self.reply(writer, 503, {'error': {'message': '图片未完整接收或校验失败，请重试'}})
        except (ValueError, json.JSONDecodeError) as error:
            if not response_started:
                if mcp_chat_request is not None:await self.reply(writer,200,mcp_text_result(mcp_ident,str(error),True))
                else:await self.reply(writer, 400, {'error': {'message': str(error)}})
        except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            if not response_started:
                if mcp_chat_request is not None:await self.reply(writer,200,mcp_text_result(mcp_ident,'远端聊天服务暂不可用，请稍后重试',True))
                else:await self.reply(writer, 503, {'error': {'message': 'chat upstream unavailable'}})
        finally:
            for task in tasks:
                task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            for stream in (upstream, writer):
                if stream:
                    stream.close()
                    try:
                        await stream.wait_closed()
                    except OSError:
                        pass


async def main(args):
    bridge = Bridge(json.loads(Path(args.config).read_text()), args.backend)
    server = await asyncio.start_server(bridge.client, '127.0.0.1', args.port)
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--port', type=int, default=18193)
    parser.add_argument('--backend', type=int, default=8190)
    asyncio.run(main(parser.parse_args()))
