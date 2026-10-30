import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/conversation.dart';

void main() {
  test(
    'Model names are shown with every word capitalised, the rest untouched',
    () {
      expect(displayModelName('Qwen3.8-Flash-Next'), 'Qwen3.8-Flash-Next');
      expect(displayModelName('qwen3-asr-1.7b'), 'Qwen3-Asr-1.7b');
      expect(displayModelName('minimax-h3'), 'Minimax-H3');
      expect(displayModelName('qwen-image-2.1-turbo'), 'Qwen-Image-2.1-Turbo');
      expect(displayModelName('fishaudio/drama-3'), 'Fishaudio/Drama-3');
      expect(displayModelName('drama 3'), 'Drama 3');
      expect(displayModelName('iq3_s'), 'Iq3_S');
      expect(displayModelName('已就绪 model'), '已就绪 Model');
      expect(displayModelName(''), '');
    },
  );
}
