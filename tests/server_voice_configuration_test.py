from pathlib import Path
import unittest,sys,copy,tempfile
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools/speech/drama3'))
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
import voice_catalog
from configure_voices import render, reserve_revisions
class Tests(unittest.TestCase):
 def setUp(self):
  self.catalog={'model':'speech','voices':[{'id':'a','name':'Alpha','description':''},{'id':'b','name':'Beta','description':''}], 'display_order':['b','a'],'default_voice':'b','voice_catalog_revision':4,'voice_default_revision':2}
 def test_status_inventory_without_voice_choices_is_unchanged(self):
  status={'id':'speech','kind':'speech','state':'ready'}
  with patch.object(voice_catalog,'load_catalog') as load:
   self.assertEqual(voice_catalog.describe_voices(status,'unused'),status);load.assert_not_called()
 def test_model_catalog_uses_central_order_default_and_revisions(self):
  with patch.object(voice_catalog,'load_catalog',return_value=self.catalog):
   result=voice_catalog.describe_voices({'id':'speech','kind':'speech','voices':['a','b'],'default_voice':'a'},'unused')
  self.assertEqual([x['id'] for x in result['voices']],['b','a']);self.assertEqual(result['default_voice'],'b');self.assertEqual(result['voice_default_revision'],2)
 def test_bad_default_and_non_integer_revision_are_rejected(self):
  for field,value in [('default_voice','missing'),('voice_default_revision',True)]:
   c=copy.deepcopy(self.catalog);c[field]=value
   with patch.object(voice_catalog,'load_catalog',return_value=c):
    with self.assertRaises(ValueError):voice_catalog.describe_voices({'id':'speech','kind':'speech','voices':['a','b']},'unused')
 def test_runtime_configs_share_one_catalog_without_mutating_inputs(self):
  cfg={'tools':[{'id':'speech','kind':'speech','options':{'unchanged':True}}]};previous=copy.deepcopy(cfg)
  voice,upstream=render(self.catalog,cfg,{'other':True},'/private/catalog.json')
  self.assertEqual(cfg,previous);self.assertEqual(voice['tools'][0]['options']['default_voice'],'b');self.assertEqual(voice['tools'][0]['options']['voices'],['b','a']);self.assertTrue(voice['tools'][0]['options']['unchanged']);self.assertEqual(upstream['voice_catalog'],voice['tools'][0]['options']['voice_catalog'])
class RevisionLedgerTests(unittest.TestCase):
 def test_rollback_cannot_reuse_revision_for_different_default(self):
  original={'model':'speech','default_voice':'a','display_order':['a','b'],'voice_catalog_revision':2,'voice_default_revision':2}
  with tempfile.TemporaryDirectory() as d:
   ledger=Path(d)/'ledger.json'
   reserve_revisions(original,ledger,original)
   changed={**original,'default_voice':'b'}
   with self.assertRaises(ValueError):reserve_revisions(changed,ledger,original)
   new={**changed,'voice_catalog_revision':3,'voice_default_revision':3}
   rollback={**original,'voice_catalog_revision':1,'voice_default_revision':1}
   reserve_revisions(new,ledger,rollback)
   reserve_revisions(new,ledger,rollback)
   with self.assertRaises(ValueError):reserve_revisions({**new,'default_voice':'a'},ledger,rollback)

class HistoricalRevisionTests(unittest.TestCase):
 def test_return_to_historical_default_requires_new_revision(self):
  with tempfile.TemporaryDirectory() as t:
   ledger=Path(t)/'ledger.json'
   a={'model':'tts','default_voice':'a','voice_catalog_revision':2,'voice_default_revision':2}
   b={**a,'default_voice':'b','voice_catalog_revision':3,'voice_default_revision':3}
   reserve_revisions(a,ledger,a);reserve_revisions(b,ledger,a)
   with self.assertRaises(ValueError):reserve_revisions({**a,'voice_catalog_revision':4},ledger,b)
   reserve_revisions({**a,'voice_catalog_revision':4,'voice_default_revision':4},ledger,b)

if __name__=='__main__':unittest.main()
