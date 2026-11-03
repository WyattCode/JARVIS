import importlib.util
from pathlib import Path
import unittest
import io
import json
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('guard', Path(__file__).resolve().parents[1] / 'deploy/jarvis/video_prompt_guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class GuardTests(unittest.TestCase):
    def test_missing_configuration_fails_closed(self):
        with patch.object(guard, 'SETTINGS', Path('/nonexistent/video-guard.json')):
            with self.assertRaisesRegex(ValueError, '尚未提交'):
                guard.prepare('original')

    def test_cancellation_is_not_converted_to_validation_error(self):
        class Cancelled(Exception):
            pass
        with patch.object(guard, 'count_tokens', side_effect=Cancelled):
            with self.assertRaises(Cancelled):
                guard.prepare('original', {})

    def test_truncated_model_output_is_never_accepted(self):
        response = io.BytesIO(json.dumps({'choices': [{'finish_reason': 'length', 'message': {'content': 'partial'}}]}).encode())
        with patch.object(guard.Path, 'read_text', return_value=json.dumps({'base_url': 'http://localhost/v1', 'model': 'test', 'api_key': 'test'})), patch.object(guard.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(ValueError, '未完整结束'):
                guard.summarize('original', {'brain_config': 'unused'}, 0)

    def test_short_prompt_preserves_exact_requirements(self):
        with patch.object(guard, 'count_tokens', return_value=512), patch.object(guard, 'summarize') as summarize:
            self.assertEqual(guard.prepare('不要字幕，保留对白', {}), '不要字幕，保留对白')
            summarize.assert_not_called()

    def test_character_count_does_not_override_token_limit(self):
        original = '海边' + ' ' * 33000
        with patch.object(guard, 'count_tokens', return_value=512), patch.object(guard, 'summarize') as summarize:
            self.assertEqual(guard.prepare(original, {}), original)
            summarize.assert_not_called()

    def test_excessive_input_is_rejected_only_after_token_check(self):
        with patch.object(guard, 'count_tokens', return_value=513), patch.object(guard, 'summarize') as summarize:
            with self.assertRaisesRegex(ValueError, '拆分场景'):
                guard.prepare('长' * 33000, {})
            summarize.assert_not_called()

    def test_first_token_over_model_limit_triggers_summary(self):
        with patch.object(guard, 'count_tokens', side_effect=[513, 100]), patch.object(guard, 'summarize', return_value='compact') as summarize:
            self.assertEqual(guard.prepare('original', {}), 'compact')
            summarize.assert_called_once()

    def test_long_prompt_rechecks_and_retries_from_original(self):
        with patch.object(guard, 'count_tokens', side_effect=[600, 420, 100]), patch.object(guard, 'summarize', side_effect=['still long', 'compact']) as summarize:
            self.assertEqual(guard.prepare('original', {}), 'compact')
            self.assertEqual([c.args[0] for c in summarize.call_args_list], ['original', 'original'])

    def test_failure_never_falls_back_to_overlong_original(self):
        with patch.object(guard, 'count_tokens', return_value=600), patch.object(guard, 'summarize', side_effect=TimeoutError):
            with self.assertRaisesRegex(ValueError, '尚未提交'):
                guard.prepare('original', {})

    def test_overlong_summary_is_refused(self):
        with patch.object(guard, 'count_tokens', return_value=600), patch.object(guard, 'summarize', return_value='too long'):
            with self.assertRaisesRegex(ValueError, '拆分场景'):
                guard.prepare('original', {})
