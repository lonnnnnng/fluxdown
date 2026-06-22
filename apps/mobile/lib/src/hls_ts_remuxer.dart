import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

Future<int> remuxTsFileToFragmentedMp4({
  required File sourceTs,
  required File outputMp4,
}) async {
  final bytes = await sourceTs.readAsBytes();
  final program = _TsProgramParser(bytes).parse();
  final movie = _Mp4Movie.fromProgram(program);
  final output = movie.writeFragmentedMp4();
  if (await outputMp4.exists()) {
    await outputMp4.delete();
  }
  await outputMp4.writeAsBytes(output, flush: true);
  return output.length;
}

// 作者: long
// 移动端不能依赖 iOS AVFoundation 稳定读取本地 TS，这里只解析 VOD HLS 常见的 H.264/AAC TS 包，再写成 fragmented MP4。
class _TsProgramParser {
  _TsProgramParser(this.bytes);

  final Uint8List bytes;
  int? _pmtPid;
  final _streamTypes = <int, int>{};
  final _pes = <int, _PesAssembler>{};
  final _videoSamples = <_VideoSample>[];
  final _audioSamples = <_AudioSample>[];
  Uint8List? _sps;
  Uint8List? _pps;
  _AacConfig? _aacConfig;

  _ParsedTsProgram parse() {
    for (var offset = 0; offset + 188 <= bytes.length; offset += 188) {
      final packet = Uint8List.sublistView(bytes, offset, offset + 188);
      if (packet[0] != 0x47) {
        throw const FormatException('MPEG-TS sync byte is missing.');
      }

      final payloadStart = (packet[1] & 0x40) != 0;
      final pid = ((packet[1] & 0x1f) << 8) | packet[2];
      final adaptationControl = (packet[3] >> 4) & 0x03;
      var payloadOffset = 4;
      if (adaptationControl == 0 || adaptationControl == 2) {
        continue;
      }
      if (adaptationControl == 3) {
        payloadOffset += 1 + packet[payloadOffset];
      }
      if (payloadOffset >= packet.length) {
        continue;
      }
      final payload = Uint8List.sublistView(packet, payloadOffset);

      if (pid == 0) {
        _parsePat(payload, payloadStart);
      } else if (_pmtPid != null && pid == _pmtPid) {
        _parsePmt(payload, payloadStart);
      } else if (_streamTypes.containsKey(pid)) {
        _parsePes(pid, payload, payloadStart);
      }
    }
    for (final pid in _pes.keys.toList(growable: false)) {
      _finishPes(pid);
    }

    if (_videoSamples.isEmpty) {
      throw const FormatException('TS HLS remux requires H.264 video samples.');
    }
    final sps = _sps;
    final pps = _pps;
    if (sps == null || pps == null) {
      throw const FormatException('TS HLS remux requires H.264 SPS/PPS.');
    }

    return _ParsedTsProgram(
      videoSamples: _videoSamples,
      audioSamples: _audioSamples,
      sps: sps,
      pps: pps,
      aacConfig: _aacConfig,
    );
  }

  void _parsePat(Uint8List payload, bool payloadStart) {
    final section = _sectionPayload(payload, payloadStart);
    if (section.length < 12 || section[0] != 0x00) {
      return;
    }
    final sectionLength = ((section[1] & 0x0f) << 8) | section[2];
    final end = math.min(section.length, 3 + sectionLength - 4);
    for (var offset = 8; offset + 4 <= end; offset += 4) {
      final programNumber = (section[offset] << 8) | section[offset + 1];
      if (programNumber == 0) {
        continue;
      }
      _pmtPid = ((section[offset + 2] & 0x1f) << 8) | section[offset + 3];
      return;
    }
  }

  void _parsePmt(Uint8List payload, bool payloadStart) {
    final section = _sectionPayload(payload, payloadStart);
    if (section.length < 16 || section[0] != 0x02) {
      return;
    }
    final sectionLength = ((section[1] & 0x0f) << 8) | section[2];
    final programInfoLength = ((section[10] & 0x0f) << 8) | section[11];
    var offset = 12 + programInfoLength;
    final end = math.min(section.length, 3 + sectionLength - 4);
    while (offset + 5 <= end) {
      final streamType = section[offset];
      final pid = ((section[offset + 1] & 0x1f) << 8) | section[offset + 2];
      final infoLength =
          ((section[offset + 3] & 0x0f) << 8) | section[offset + 4];
      if (streamType == 0x1b || streamType == 0x0f) {
        _streamTypes[pid] = streamType;
      }
      offset += 5 + infoLength;
    }
  }

  Uint8List _sectionPayload(Uint8List payload, bool payloadStart) {
    if (!payloadStart || payload.isEmpty) {
      return payload;
    }
    final pointer = payload[0];
    final offset = 1 + pointer;
    if (offset >= payload.length) {
      return Uint8List(0);
    }
    return Uint8List.sublistView(payload, offset);
  }

  void _parsePes(int pid, Uint8List payload, bool payloadStart) {
    if (payloadStart) {
      _finishPes(pid);
      _pes[pid] = _PesAssembler(streamType: _streamTypes[pid]!)..add(payload);
    } else {
      _pes[pid]?.add(payload);
    }
  }

  void _finishPes(int pid) {
    final assembler = _pes.remove(pid);
    if (assembler == null) {
      return;
    }
    final packet = _PesPacket.tryParse(assembler.bytes, assembler.streamType);
    if (packet == null) {
      return;
    }
    if (packet.streamType == 0x1b) {
      _consumeH264Pes(packet);
    } else if (packet.streamType == 0x0f) {
      _consumeAacPes(packet);
    }
  }

  void _consumeH264Pes(_PesPacket packet) {
    final nals = _splitAnnexBNals(packet.payload);
    if (nals.isEmpty) {
      return;
    }
    final sampleBytes = BytesBuilder(copy: false);
    var keyframe = false;
    for (final nal in nals) {
      final type = nal[0] & 0x1f;
      if (type == 7) {
        _sps = nal;
      } else if (type == 8) {
        _pps = nal;
      } else if (type == 5 || type == 1 || type == 6) {
        if (type == 5) {
          keyframe = true;
        }
        sampleBytes.add(_u32(nal.length));
        sampleBytes.add(nal);
      }
    }
    final data = sampleBytes.takeBytes();
    if (data.isEmpty || packet.pts == null) {
      return;
    }
    _videoSamples.add(
      _VideoSample(
        pts90: packet.pts!,
        dts90: packet.dts ?? packet.pts!,
        data: data,
        keyframe: keyframe,
      ),
    );
  }

  void _consumeAacPes(_PesPacket packet) {
    if (packet.pts == null) {
      return;
    }
    var offset = 0;
    var frameIndex = 0;
    while (offset + 7 <= packet.payload.length) {
      if (packet.payload[offset] != 0xff ||
          (packet.payload[offset + 1] & 0xf0) != 0xf0) {
        offset += 1;
        continue;
      }
      final protectionAbsent = packet.payload[offset + 1] & 0x01;
      final profile = (packet.payload[offset + 2] >> 6) & 0x03;
      final sampleRateIndex = (packet.payload[offset + 2] >> 2) & 0x0f;
      final channelConfig =
          ((packet.payload[offset + 2] & 0x01) << 2) |
          ((packet.payload[offset + 3] >> 6) & 0x03);
      final frameLength =
          ((packet.payload[offset + 3] & 0x03) << 11) |
          (packet.payload[offset + 4] << 3) |
          ((packet.payload[offset + 5] >> 5) & 0x07);
      final headerLength = protectionAbsent == 1 ? 7 : 9;
      if (frameLength <= headerLength ||
          offset + frameLength > packet.payload.length) {
        break;
      }
      final sampleRate = _aacSampleRates[sampleRateIndex];
      if (sampleRate == null) {
        throw FormatException(
          'Unsupported AAC sample-rate index: $sampleRateIndex',
        );
      }
      _aacConfig ??= _AacConfig(
        objectType: profile + 1,
        sampleRate: sampleRate,
        sampleRateIndex: sampleRateIndex,
        channelConfig: channelConfig,
      );
      final data = Uint8List.sublistView(
        packet.payload,
        offset + headerLength,
        offset + frameLength,
      );
      _audioSamples.add(
        _AudioSample(
          pts90: packet.pts! + ((frameIndex * 1024 * 90000) ~/ sampleRate),
          data: data,
        ),
      );
      frameIndex += 1;
      offset += frameLength;
    }
  }
}

class _PesAssembler {
  _PesAssembler({required this.streamType});

  final int streamType;
  final _builder = BytesBuilder(copy: false);

  void add(Uint8List bytes) => _builder.add(bytes);

  Uint8List get bytes => _builder.takeBytes();
}

class _PesPacket {
  const _PesPacket({
    required this.streamType,
    required this.payload,
    required this.pts,
    required this.dts,
  });

  final int streamType;
  final Uint8List payload;
  final int? pts;
  final int? dts;

  static _PesPacket? tryParse(Uint8List bytes, int streamType) {
    if (bytes.length < 9 ||
        bytes[0] != 0x00 ||
        bytes[1] != 0x00 ||
        bytes[2] != 0x01) {
      return null;
    }
    final flags = (bytes[7] >> 6) & 0x03;
    final headerLength = bytes[8];
    int? pts;
    int? dts;
    if ((flags & 0x02) != 0 && bytes.length >= 14) {
      pts = _readPts(bytes, 9);
    }
    if ((flags & 0x01) != 0 && bytes.length >= 19) {
      dts = _readPts(bytes, 14);
    }
    final payloadOffset = 9 + headerLength;
    if (payloadOffset > bytes.length) {
      return null;
    }
    return _PesPacket(
      streamType: streamType,
      payload: Uint8List.sublistView(bytes, payloadOffset),
      pts: pts,
      dts: dts,
    );
  }
}

class _ParsedTsProgram {
  const _ParsedTsProgram({
    required this.videoSamples,
    required this.audioSamples,
    required this.sps,
    required this.pps,
    required this.aacConfig,
  });

  final List<_VideoSample> videoSamples;
  final List<_AudioSample> audioSamples;
  final Uint8List sps;
  final Uint8List pps;
  final _AacConfig? aacConfig;
}

class _VideoSample {
  _VideoSample({
    required this.pts90,
    required this.dts90,
    required this.data,
    required this.keyframe,
  });

  final int pts90;
  final int dts90;
  final Uint8List data;
  final bool keyframe;
  int duration90 = 0;
}

class _AudioSample {
  const _AudioSample({required this.pts90, required this.data});

  final int pts90;
  final Uint8List data;
}

class _AacConfig {
  const _AacConfig({
    required this.objectType,
    required this.sampleRate,
    required this.sampleRateIndex,
    required this.channelConfig,
  });

  final int objectType;
  final int sampleRate;
  final int sampleRateIndex;
  final int channelConfig;

  Uint8List get audioSpecificConfig {
    final first = (objectType << 3) | (sampleRateIndex >> 1);
    final second = ((sampleRateIndex & 0x01) << 7) | (channelConfig << 3);
    return Uint8List.fromList([first, second]);
  }
}

class _Mp4Movie {
  _Mp4Movie({
    required this.videoSamples,
    required this.audioSamples,
    required this.sps,
    required this.pps,
    required this.aacConfig,
    required this.videoInfo,
    required this.earliestPts90,
  });

  final List<_VideoSample> videoSamples;
  final List<_AudioSample> audioSamples;
  final Uint8List sps;
  final Uint8List pps;
  final _AacConfig? aacConfig;
  final _SpsInfo videoInfo;
  final int earliestPts90;

  static _Mp4Movie fromProgram(_ParsedTsProgram program) {
    final videoSamples = [...program.videoSamples]
      ..sort((a, b) => a.dts90.compareTo(b.dts90));
    for (var index = 0; index < videoSamples.length; index += 1) {
      if (index + 1 < videoSamples.length) {
        videoSamples[index].duration90 =
            videoSamples[index + 1].dts90 - videoSamples[index].dts90;
      } else {
        videoSamples[index].duration90 = index == 0
            ? 6000
            : videoSamples[index - 1].duration90;
      }
      if (videoSamples[index].duration90 <= 0) {
        videoSamples[index].duration90 = 6000;
      }
    }
    final audioSamples = [...program.audioSamples]
      ..sort((a, b) => a.pts90.compareTo(b.pts90));
    final earliest = <int>[
      if (videoSamples.isNotEmpty) videoSamples.first.dts90,
      if (audioSamples.isNotEmpty) audioSamples.first.pts90,
    ].reduce(math.min);
    return _Mp4Movie(
      videoSamples: videoSamples,
      audioSamples: audioSamples,
      sps: program.sps,
      pps: program.pps,
      aacConfig: program.aacConfig,
      videoInfo: _SpsInfo.parse(program.sps),
      earliestPts90: earliest,
    );
  }

  Uint8List writeFragmentedMp4() {
    final output = BytesBuilder(copy: false)
      ..add(_ftyp())
      ..add(_moov());
    var sequence = 1;
    final fragments =
        <_FragmentSample>[
          for (final sample in videoSamples)
            _FragmentSample.video(
              sequence: sequence++,
              decodeTime: sample.dts90 - earliestPts90,
              duration: sample.duration90,
              compositionOffset: sample.pts90 - sample.dts90,
              data: sample.data,
              keyframe: sample.keyframe,
            ),
          if (aacConfig != null)
            for (var index = 0; index < audioSamples.length; index += 1)
              _FragmentSample.audio(
                sequence: sequence++,
                decodeTime:
                    (((audioSamples[index].pts90 - earliestPts90) *
                                aacConfig!.sampleRate) /
                            90000)
                        .round(),
                sampleRate: aacConfig!.sampleRate,
                data: audioSamples[index].data,
              ),
        ]..sort((a, b) {
          final byTime = a.timelineMicros.compareTo(b.timelineMicros);
          return byTime == 0 ? a.trackId.compareTo(b.trackId) : byTime;
        });
    for (final fragment in fragments) {
      output
        ..add(fragment.moof())
        ..add(_box('mdat', [fragment.data]));
    }
    return output.takeBytes();
  }

  Uint8List _ftyp() => _box('ftyp', [
    _ascii('iso5'),
    _u32(0x00000200),
    _ascii('iso5'),
    _ascii('iso6'),
    _ascii('mp41'),
    _ascii('avc1'),
    _ascii('mp42'),
  ]);

  Uint8List _moov() {
    return _box('moov', [
      _mvhd(),
      _videoTrak(),
      if (aacConfig != null) _audioTrak(),
      _mvex(),
    ]);
  }

  Uint8List _mvhd() => _fullBox('mvhd', 0, 0, [
    _u32(0),
    _u32(0),
    _u32(1000),
    _u32(0),
    _u32(0x00010000),
    _u16(0x0100),
    _u16(0),
    _u32(0),
    _u32(0),
    _unityMatrix(),
    Uint8List(24),
    _u32(3),
  ]);

  Uint8List _videoTrak() => _trak(
    trackId: 1,
    handler: 'vide',
    name: 'VideoHandler',
    timescale: 90000,
    volume: 0,
    width: videoInfo.width,
    height: videoInfo.height,
    mediaHeader: _fullBox('vmhd', 0, 1, [_u16(0), _u16(0), _u16(0), _u16(0)]),
    sampleEntry: _avc1(),
  );

  Uint8List _audioTrak() {
    final config = aacConfig!;
    return _trak(
      trackId: 2,
      handler: 'soun',
      name: 'SoundHandler',
      timescale: config.sampleRate,
      volume: 0x0100,
      width: 0,
      height: 0,
      mediaHeader: _fullBox('smhd', 0, 0, [_u16(0), _u16(0)]),
      sampleEntry: _mp4a(config),
    );
  }

  Uint8List _trak({
    required int trackId,
    required String handler,
    required String name,
    required int timescale,
    required int volume,
    required int width,
    required int height,
    required Uint8List mediaHeader,
    required Uint8List sampleEntry,
  }) {
    return _box('trak', [
      _tkhd(trackId, volume, width, height),
      _box('mdia', [
        _mdhd(timescale),
        _hdlr(handler, name),
        _box('minf', [mediaHeader, _dinf(), _stbl(sampleEntry)]),
      ]),
    ]);
  }

  Uint8List _tkhd(int trackId, int volume, int width, int height) {
    return _fullBox('tkhd', 0, 7, [
      _u32(0),
      _u32(0),
      _u32(trackId),
      _u32(0),
      _u32(0),
      _u32(0),
      _u32(0),
      _u16(0),
      _u16(0),
      _u16(volume),
      _u16(0),
      _unityMatrix(),
      _u32(width << 16),
      _u32(height << 16),
    ]);
  }

  Uint8List _mdhd(int timescale) => _fullBox('mdhd', 0, 0, [
    _u32(0),
    _u32(0),
    _u32(timescale),
    _u32(0),
    _u16(0x55c4),
    _u16(0),
  ]);

  Uint8List _hdlr(String handler, String name) => _fullBox('hdlr', 0, 0, [
    _u32(0),
    _ascii(handler),
    _u32(0),
    _u32(0),
    _u32(0),
    _ascii('$name\x00'),
  ]);

  Uint8List _dinf() => _box('dinf', [
    _fullBox('dref', 0, 0, [_u32(1), _fullBox('url ', 0, 1, const [])]),
  ]);

  Uint8List _stbl(Uint8List sampleEntry) => _box('stbl', [
    _fullBox('stsd', 0, 0, [_u32(1), sampleEntry]),
    _fullBox('stts', 0, 0, [_u32(0)]),
    _fullBox('stsc', 0, 0, [_u32(0)]),
    _fullBox('stsz', 0, 0, [_u32(0), _u32(0)]),
    _fullBox('stco', 0, 0, [_u32(0)]),
  ]);

  Uint8List _avc1() => _box('avc1', [
    Uint8List(6),
    _u16(1),
    Uint8List(16),
    _u16(videoInfo.width),
    _u16(videoInfo.height),
    _u32(0x00480000),
    _u32(0x00480000),
    _u32(0),
    _u16(1),
    Uint8List(32),
    _u16(0x0018),
    _u16(0xffff),
    _avcC(),
  ]);

  Uint8List _avcC() => _box('avcC', [
    Uint8List.fromList([
      1,
      sps.length > 1 ? sps[1] : 0x64,
      sps.length > 2 ? sps[2] : 0,
      sps.length > 3 ? sps[3] : 0x1f,
      0xff,
      0xe1,
    ]),
    _u16(sps.length),
    sps,
    Uint8List.fromList([1]),
    _u16(pps.length),
    pps,
  ]);

  Uint8List _mp4a(_AacConfig config) => _box('mp4a', [
    Uint8List(6),
    _u16(1),
    Uint8List(8),
    _u16(config.channelConfig),
    _u16(16),
    _u16(0),
    _u16(0),
    _u32(config.sampleRate << 16),
    _esds(config),
  ]);

  Uint8List _esds(_AacConfig config) {
    final decoderSpecific = _descriptor(0x05, [config.audioSpecificConfig]);
    final decoderConfig = _descriptor(0x04, [
      Uint8List.fromList([0x40, 0x15, 0, 0, 0]),
      _u32(0),
      _u32(0),
      decoderSpecific,
    ]);
    final es = _descriptor(0x03, [
      _u16(1),
      Uint8List.fromList([0]),
      decoderConfig,
      _descriptor(0x06, [
        Uint8List.fromList([0x02]),
      ]),
    ]);
    return _fullBox('esds', 0, 0, [es]);
  }

  Uint8List _mvex() =>
      _box('mvex', [_trex(1), if (aacConfig != null) _trex(2)]);

  Uint8List _trex(int trackId) => _fullBox('trex', 0, 0, [
    _u32(trackId),
    _u32(1),
    _u32(0),
    _u32(0),
    _u32(0),
  ]);
}

// 作者: long
// 每个 sample 独立写一个 moof/mdat，牺牲一点体积换取实现稳定，避免一次性计算复杂的跨轨道 trun data-offset。
class _FragmentSample {
  _FragmentSample({
    required this.sequence,
    required this.trackId,
    required this.decodeTime,
    required this.timescale,
    required this.duration,
    required this.data,
    required this.sampleFlags,
    required this.compositionOffset,
  });

  factory _FragmentSample.video({
    required int sequence,
    required int decodeTime,
    required int duration,
    required int compositionOffset,
    required Uint8List data,
    required bool keyframe,
  }) {
    return _FragmentSample(
      sequence: sequence,
      trackId: 1,
      decodeTime: math.max(0, decodeTime),
      timescale: 90000,
      duration: duration,
      data: data,
      sampleFlags: keyframe ? 0x02000000 : 0x01010000,
      compositionOffset: compositionOffset,
    );
  }

  factory _FragmentSample.audio({
    required int sequence,
    required int decodeTime,
    required int sampleRate,
    required Uint8List data,
  }) {
    return _FragmentSample(
      sequence: sequence,
      trackId: 2,
      decodeTime: math.max(0, decodeTime),
      timescale: sampleRate,
      duration: 1024,
      data: data,
      sampleFlags: 0,
      compositionOffset: 0,
    );
  }

  final int sequence;
  final int trackId;
  final int decodeTime;
  final int timescale;
  final int duration;
  final Uint8List data;
  final int sampleFlags;
  final int compositionOffset;

  int get timelineMicros => ((decodeTime * 1000000) / timescale).round();

  Uint8List moof() {
    Uint8List build(int dataOffset) => _box('moof', [
      _fullBox('mfhd', 0, 0, [_u32(sequence)]),
      _box('traf', [
        _fullBox('tfhd', 0, 0x020000, [_u32(trackId)]),
        _fullBox('tfdt', 1, 0, [_u64(decodeTime)]),
        _fullBox('trun', 1, 0x000f01, [
          _u32(1),
          _i32(dataOffset),
          _u32(duration),
          _u32(data.length),
          _u32(sampleFlags),
          _i32(compositionOffset),
        ]),
      ]),
    ]);

    final probe = build(0);
    return build(probe.length + 8);
  }
}

class _SpsInfo {
  const _SpsInfo({required this.width, required this.height});

  final int width;
  final int height;

  static _SpsInfo parse(Uint8List sps) {
    final reader = _BitReader(_removeEmulationPrevention(sps.sublist(1)));
    final profileIdc = reader.readBits(8);
    reader.readBits(8);
    reader.readBits(8);
    reader.readUnsignedExpGolomb();
    var chromaFormatIdc = 1;
    if ({
      100,
      110,
      122,
      244,
      44,
      83,
      86,
      118,
      128,
      138,
      139,
      134,
    }.contains(profileIdc)) {
      chromaFormatIdc = reader.readUnsignedExpGolomb();
      if (chromaFormatIdc == 3) {
        reader.readBits(1);
      }
      reader.readUnsignedExpGolomb();
      reader.readUnsignedExpGolomb();
      reader.readBits(1);
      if (reader.readBits(1) == 1) {
        final count = chromaFormatIdc == 3 ? 12 : 8;
        for (var index = 0; index < count; index += 1) {
          if (reader.readBits(1) == 1) {
            _skipScalingList(reader, index < 6 ? 16 : 64);
          }
        }
      }
    }
    reader.readUnsignedExpGolomb();
    final picOrderCntType = reader.readUnsignedExpGolomb();
    if (picOrderCntType == 0) {
      reader.readUnsignedExpGolomb();
    } else if (picOrderCntType == 1) {
      reader.readBits(1);
      reader.readSignedExpGolomb();
      reader.readSignedExpGolomb();
      final cycle = reader.readUnsignedExpGolomb();
      for (var index = 0; index < cycle; index += 1) {
        reader.readSignedExpGolomb();
      }
    }
    reader.readUnsignedExpGolomb();
    reader.readBits(1);
    final widthInMbsMinus1 = reader.readUnsignedExpGolomb();
    final heightInMapUnitsMinus1 = reader.readUnsignedExpGolomb();
    final frameMbsOnlyFlag = reader.readBits(1);
    if (frameMbsOnlyFlag == 0) {
      reader.readBits(1);
    }
    reader.readBits(1);
    var cropLeft = 0;
    var cropRight = 0;
    var cropTop = 0;
    var cropBottom = 0;
    if (reader.readBits(1) == 1) {
      cropLeft = reader.readUnsignedExpGolomb();
      cropRight = reader.readUnsignedExpGolomb();
      cropTop = reader.readUnsignedExpGolomb();
      cropBottom = reader.readUnsignedExpGolomb();
    }
    final cropUnitX = chromaFormatIdc == 0 ? 1 : 2;
    final cropUnitY = chromaFormatIdc == 0
        ? 2 - frameMbsOnlyFlag
        : 2 * (2 - frameMbsOnlyFlag);
    final width =
        ((widthInMbsMinus1 + 1) * 16) - (cropLeft + cropRight) * cropUnitX;
    final height =
        ((2 - frameMbsOnlyFlag) * (heightInMapUnitsMinus1 + 1) * 16) -
        (cropTop + cropBottom) * cropUnitY;
    return _SpsInfo(width: width, height: height);
  }
}

class _BitReader {
  _BitReader(this.bytes);

  final Uint8List bytes;
  var _bitOffset = 0;

  int readBits(int count) {
    var value = 0;
    for (var index = 0; index < count; index += 1) {
      final byte = bytes[_bitOffset >> 3];
      value = (value << 1) | ((byte >> (7 - (_bitOffset & 7))) & 1);
      _bitOffset += 1;
    }
    return value;
  }

  int readUnsignedExpGolomb() {
    var zeros = 0;
    while (readBits(1) == 0) {
      zeros += 1;
    }
    return (1 << zeros) - 1 + (zeros == 0 ? 0 : readBits(zeros));
  }

  int readSignedExpGolomb() {
    final value = readUnsignedExpGolomb();
    return value.isOdd ? (value + 1) ~/ 2 : -(value ~/ 2);
  }
}

const _aacSampleRates = <int, int>{
  0: 96000,
  1: 88200,
  2: 64000,
  3: 48000,
  4: 44100,
  5: 32000,
  6: 24000,
  7: 22050,
  8: 16000,
  9: 12000,
  10: 11025,
  11: 8000,
  12: 7350,
};

List<Uint8List> _splitAnnexBNals(Uint8List payload) {
  final starts = <({int offset, int length})>[];
  var index = 0;
  while (index + 3 < payload.length) {
    if (payload[index] == 0 &&
        payload[index + 1] == 0 &&
        payload[index + 2] == 1) {
      starts.add((offset: index, length: 3));
      index += 3;
    } else if (index + 4 < payload.length &&
        payload[index] == 0 &&
        payload[index + 1] == 0 &&
        payload[index + 2] == 0 &&
        payload[index + 3] == 1) {
      starts.add((offset: index, length: 4));
      index += 4;
    } else {
      index += 1;
    }
  }
  return [
    for (var i = 0; i < starts.length; i += 1)
      if ((i + 1 < starts.length ? starts[i + 1].offset : payload.length) >
          starts[i].offset + starts[i].length)
        Uint8List.sublistView(
          payload,
          starts[i].offset + starts[i].length,
          i + 1 < starts.length ? starts[i + 1].offset : payload.length,
        ),
  ];
}

int _readPts(Uint8List bytes, int offset) {
  return ((bytes[offset] & 0x0e) << 29) |
      (bytes[offset + 1] << 22) |
      ((bytes[offset + 2] & 0xfe) << 14) |
      (bytes[offset + 3] << 7) |
      ((bytes[offset + 4] & 0xfe) >> 1);
}

Uint8List _removeEmulationPrevention(Uint8List bytes) {
  final out = BytesBuilder(copy: false);
  for (var index = 0; index < bytes.length; index += 1) {
    if (index + 2 < bytes.length &&
        bytes[index] == 0 &&
        bytes[index + 1] == 0 &&
        bytes[index + 2] == 3) {
      out.add(Uint8List.fromList([0, 0]));
      index += 2;
    } else {
      out.addByte(bytes[index]);
    }
  }
  return out.takeBytes();
}

void _skipScalingList(_BitReader reader, int size) {
  var lastScale = 8;
  var nextScale = 8;
  for (var index = 0; index < size; index += 1) {
    if (nextScale != 0) {
      final deltaScale = reader.readSignedExpGolomb();
      nextScale = (lastScale + deltaScale + 256) % 256;
    }
    lastScale = nextScale == 0 ? lastScale : nextScale;
  }
}

Uint8List _box(String type, List<Uint8List> payloads) {
  final size = 8 + payloads.fold<int>(0, (total, item) => total + item.length);
  final builder = BytesBuilder(copy: false)
    ..add(_u32(size))
    ..add(_ascii(type));
  for (final payload in payloads) {
    builder.add(payload);
  }
  return builder.takeBytes();
}

Uint8List _fullBox(
  String type,
  int version,
  int flags,
  List<Uint8List> payloads,
) {
  return _box(type, [
    Uint8List.fromList([
      version & 0xff,
      (flags >> 16) & 0xff,
      (flags >> 8) & 0xff,
      flags & 0xff,
    ]),
    ...payloads,
  ]);
}

Uint8List _descriptor(int tag, List<Uint8List> payloads) {
  final payloadBuilder = BytesBuilder(copy: false);
  for (final payload in payloads) {
    payloadBuilder.add(payload);
  }
  final payload = payloadBuilder.takeBytes();
  return Uint8List.fromList([
    tag,
    ..._descriptorLength(payload.length),
    ...payload,
  ]);
}

List<int> _descriptorLength(int length) {
  final bytes = <int>[(length & 0x7f)];
  length >>= 7;
  while (length > 0) {
    bytes.insert(0, 0x80 | (length & 0x7f));
    length >>= 7;
  }
  return bytes;
}

Uint8List _unityMatrix() => Uint8List.fromList([
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x40,
  0x00,
  0x00,
  0x00,
]);

Uint8List _ascii(String value) => Uint8List.fromList(value.codeUnits);

Uint8List _u16(int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value);

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

Uint8List _i32(int value) =>
    Uint8List(4)..buffer.asByteData().setInt32(0, value);

Uint8List _u64(int value) {
  final bytes = Uint8List(8);
  final data = bytes.buffer.asByteData();
  data.setUint32(0, value ~/ 0x100000000);
  data.setUint32(4, value & 0xffffffff);
  return bytes;
}
