import 'package:fire_adb/shell/shell_output.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShellOutputBuffer', () {
    late ShellOutputBuffer output;

    setUp(() {
      output = ShellOutputBuffer();
    });

    tearDown(() {
      output.dispose();
    });

    test('batches text into chunks without losing content', () {
      final text = 'x' * 9000;
      output.appendText(ShellOutputType.output, text);
      output.flush();

      expect(output.segments.length, greaterThan(1));
      expect(output.segments.map((segment) => segment.text).join(), text);
    });

    test('keeps many lines and truncates by character capacity only', () {
      final text = List<String>.generate(
        1200,
        (index) => 'line $index\n',
      ).join();
      output.appendText(ShellOutputType.output, text);
      output.flush();

      expect(output.segments.map((segment) => segment.text).join(), text);
      expect(output.truncated, isFalse);

      output.setLimitMiB(1);
      output.appendText(ShellOutputType.output, 'y' * (1024 * 1024 + 10));
      output.flush();

      final retainedText = output.segments
          .map((segment) => segment.text)
          .join();
      expect(retainedText.length, lessThanOrEqualTo(1024 * 1024));
      expect(retainedText.endsWith('y' * (1024 * 1024)), isTrue);
      expect(output.truncated, isTrue);
    });
  });
}
