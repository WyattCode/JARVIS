import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('voice_catalog_tested',Path(__file__).parents[1]/'tools/speech/drama3/voice_catalog.py')
catalog=importlib.util.module_from_spec(spec);spec.loader.exec_module(catalog)

class VoiceCatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);p=Path(self.temp.name)
        rows=[[i,2] for i in range(10)]
        digest=hashlib.sha256(b''.join(x.to_bytes(4,'little',signed=True) for row in rows for x in row)).hexdigest()
        reference={'format':'drama3-voice/1','source':{'kind':'model-invented'},'text':'中文参考','vq_codes':rows,'codes_sha256':digest}
        self.ref=p/'reference.json';self.ref.write_text(json.dumps(reference));self.path=p/'catalog.json'
        self.value={'format':'jarvis-voices/1','model':'speech','voices':[{'id':'zh-test','name':'测试声线','description':'中文固定参考','base_voice':'Mae','reference_file':str(self.ref),'reference_sha256':hashlib.sha256(self.ref.read_bytes()).hexdigest()}]};self.save()
    def save(self):
        catalog.load_catalog.cache_clear();self.path.write_text(json.dumps(self.value))
    def test_maps_only_configured_voice_and_preserves_stream(self):
        body={'model':'speech','voice':'zh-test','input':'你好','stream':True,'response_format':'pcm'};original=copy.deepcopy(body)
        result=catalog.speech_body(body,self.path)
        self.assertEqual(result['voice'],'Mae');self.assertEqual(result['references'][0]['text'],'中文参考');self.assertTrue(result['stream']);self.assertEqual(result['response_format'],'pcm');self.assertEqual(body,original)
    def test_original_voices_and_other_models_unchanged(self):
        for body in [{'model':'speech','voice':'Mae'},{'model':'other','voice':'zh-test'},{'model':'speech','voice':'../../secret'}]:self.assertIs(catalog.speech_body(body,self.path),body)
    def test_refuses_conflicting_references(self):
        with self.assertRaises(ValueError):catalog.speech_body({'model':'speech','voice':'zh-test','references':[{'text':'other'}]},self.path)
    def test_pins_reference_bytes(self):
        self.ref.write_text('{}')
        with self.assertRaisesRegex(ValueError,'digest'):catalog.load_catalog(self.path)
    def test_metadata_never_advertises_unaccepted_voice_or_private_codes(self):
        model={'id':'speech','kind':'speech','default_voice':'Mae','voices':['zh-test','Mae']}
        result=catalog.describe_voices(model,self.path)
        self.assertEqual(result['default_voice'],'Mae');self.assertEqual(result['voices'][0],{'id':'zh-test','name':'测试声线','description':'中文固定参考'});self.assertEqual(result['voices'][1],'Mae');self.assertNotIn('reference',json.dumps(result))
        self.assertEqual(catalog.describe_voices(dict(model,voices=['Mae']),self.path)['voices'],['Mae'])
    def test_detects_code_grid_tampering_even_with_updated_file_hash(self):
        value=json.loads(self.ref.read_text());value['vq_codes'][0][0]=3000;self.ref.write_text(json.dumps(value));self.value['voices'][0]['reference_sha256']=hashlib.sha256(self.ref.read_bytes()).hexdigest();self.save()
        with self.assertRaisesRegex(ValueError,'content'):catalog.load_catalog(self.path)
    def test_four_distinct_ids_keep_their_own_reference_across_requests(self):
        original=self.value['voices'][0]
        self.value['voices']=[dict(original,id=f'zh-test-{i}',base_voice=base) for i,base in enumerate(['Ezra','Arlo','Nora','Mae'])];self.save()
        for _ in range(2):
            for i,base in enumerate(['Ezra','Arlo','Nora','Mae']):
                result=catalog.speech_body({'model':'speech','voice':f'zh-test-{i}'},self.path);self.assertEqual(result['voice'],base);self.assertEqual(len(result['references']),1)
    def test_pinned_preview_has_no_path_or_codes_in_metadata(self):
        preview=Path(self.temp.name)/'preview.wav';preview.write_bytes(b'RIFF'+bytes(100))
        self.value['voices'][0].update(preview_file=str(preview),preview_sha256=hashlib.sha256(preview.read_bytes()).hexdigest());self.save()
        self.assertEqual(catalog.preview_audio(self.path,'zh-test'),preview.read_bytes())
        self.assertIsNone(catalog.preview_audio(self.path,'../../preview'))
        model=catalog.describe_voices({'id':'speech','kind':'speech','voices':['zh-test']},self.path)
        self.assertEqual(model['voices'][0]['preview_url'],'/v1/voice-previews/zh-test.wav')
        self.assertNotIn(str(self.temp.name),json.dumps(model))
        preview.write_bytes(b'bad');catalog.load_catalog.cache_clear()
        with self.assertRaisesRegex(ValueError,'preview'):catalog.load_catalog(self.path)
    def test_original_preview_preserves_default_order_and_synthesis(self):
        preview=Path(self.temp.name)/'Mae.wav';preview.write_bytes(b'RIFF'+bytes(100))
        self.value.update(display_labels={'Mae':{'name':'Mae','description':'original'}},display_order=['Mae','zh-test'],previews={'Mae':{'preview_file':str(preview),'preview_sha256':hashlib.sha256(preview.read_bytes()).hexdigest()}});self.save()
        model=catalog.describe_voices({'id':'speech','kind':'speech','default_voice':'Mae','voices':['zh-test','Mae']},self.path)
        self.assertEqual([v['id'] for v in model['voices']],['Mae','zh-test']);self.assertEqual(model['default_voice'],'Mae')
        self.assertEqual(model['voices'][0]['preview_url'],'/v1/voice-previews/Mae.wav');self.assertEqual(catalog.preview_audio(self.path,'Mae'),preview.read_bytes())
        body={'model':'speech','voice':'Mae','input':'normal speech'};self.assertIs(catalog.speech_body(body,self.path),body)
        self.assertNotIn(str(self.temp.name),json.dumps(model));self.assertIsNone(catalog.preview_audio(self.path,'../../Mae'))
        preview.write_bytes(b'broken');catalog.load_catalog.cache_clear()
        with self.assertRaisesRegex(ValueError,'preview'):catalog.load_catalog(self.path)

    def test_refuses_duplicate_catalog_ids(self):
        self.value['voices']*=2;self.save()
        with self.assertRaisesRegex(ValueError,'duplicate'):catalog.load_catalog(self.path)

if __name__=='__main__':unittest.main()
