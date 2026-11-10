import 'package:flutter_test/flutter_test.dart';
import 'package:qingyunmusic/models.dart';

void main() {
  test('parseLrc 解析时间标签并应用 offset', () {
    const raw = '[offset:500]\n'
        '[00:01.00]第一行\n'
        '[00:02.50]第二行\n'
        '[00:03.00][00:04.00]重复行\n';
    final lines = parseLrc(raw);

    expect(lines.length, 4);
    expect(lines.first.text, '第一行');
    expect(lines.first.time, const Duration(milliseconds: 500));
    expect(lines[1].time, const Duration(milliseconds: 2000));
    expect(parseLrc('没有时间标签的文本').isEmpty, isTrue);
  });

  test('formatDuration 处理空值与正常时长', () {
    expect(formatDuration(null), '--:--');
    expect(formatDuration(Duration.zero), '--:--');
    expect(formatDuration(const Duration(minutes: 3, seconds: 7)), '3:07');
  });

  test('Song.fromJson 缺字段时使用默认值', () {
    final song = Song.fromJson({'id': 'abc', 'name': '夜曲'});

    expect(song.id, 'abc');
    expect(song.name, '夜曲');
    expect(song.artist, '未知艺术家');
    expect(song.hasLrc, isFalse);
    expect(song.hasCover, isFalse);
    expect(song.matches('夜'), isTrue);
    expect(song.matches('不存在的词'), isFalse);
  });
}
