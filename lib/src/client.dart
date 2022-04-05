import 'dart:convert' show base64, jsonDecode, jsonEncode, utf8;
import 'dart:math' show min;
import 'dart:typed_data' show Uint8List, BytesBuilder;
import 'exceptions.dart';
import 'store.dart';

import 'package:cross_file/cross_file.dart' show XFile;
import 'package:http/http.dart' as http;

/// This class is used for creating or resuming uploads.
class TusClient {
  /// Version of the tus protocol used by the client. The remote server needs to
  /// support this version, too.
  static final tusVersion = "1.0.0";

  /// The tus server Uri
  final Uri url;

  /// Storage used to save and retrieve upload URLs by its fingerprint.
  final TusStore? store;

  final XFile file;

  /// Any additional headers
  final Map<String, String>? headers;

  /// Vimeo API token
  final String token;

  /// body
  final Map<String, dynamic>? body;

  /// The maximum payload size in bytes when uploading the file in chunks (512KB)
  int maxChunkSize;

  int? _fileSize;

  String _fingerprint = "";

  Uri? _uploadUrl;

  int? _offset;

  bool _pauseUpload = false;

  bool _processingVideo = false;

  Future<http.Response?>? _chunkPatchFuture;

  http.Response? _vimeoDetails;

  TusClient(
    this.url,
    this.file, {
    this.store,
    this.headers,
    this.body,
    required this.token,
    this.maxChunkSize = 1024 * 1024, //1MB
    // this.maxChunkSize = 512000, //512KB
    // this.maxChunkSize = 10000000, //10MB
  }) {
    _fingerprint = generateFingerprint() ?? "";
  }

  /// Whether the client supports resuming
  bool get resumingEnabled => store != null;

  /// true if video is uploaded and transcoding
  bool get isVideoProcessing => _processingVideo;

  /// The URI on the server for the file
  Uri? get uploadUrl => _uploadUrl;

  /// Response of Vimeo Post request
  http.Response? get vimeoDetails => _vimeoDetails;

  /// The fingerprint of the file being uploaded
  String get fingerprint => _fingerprint;

  /// Override this method to use a custom Client
  http.Client getHttpClient() => http.Client();

  /// Create a new [upload] throwing [ProtocolException] on server error
  create() async {
    _fileSize = await file.length();
    if (_fileSize != null) {
      maxChunkSize = int.parse((_fileSize! / 10).toString());
    }

    final client = getHttpClient();
    final createHeaders = Map<String, String>.from(headers ?? {})
      ..addAll({"Authorization": "Bearer $token"});

    final response = await client.post(
      url,
      headers: createHeaders,
      body: jsonEncode(body),
    );
    if (!(response.statusCode >= 200 && response.statusCode < 300) &&
        response.statusCode != 404) {
      throw ProtocolException(
          "unexpected status code (${response.statusCode}) while creating upload");
    }

    _vimeoDetails = response;

    String urlStr = await jsonDecode(response.body)['upload']['upload_link'];
    if (urlStr.isEmpty) {
      throw ProtocolException(
          "missing upload Uri in response for creating upload");
    }

    _uploadUrl = _parseUrl(urlStr);
    store?.set(_fingerprint, _uploadUrl as Uri);
  }

  /// Check if possible to resume an already started upload
  Future<bool> resume() async {
    _fileSize = await file.length();
    _pauseUpload = false;

    if (!resumingEnabled) {
      return false;
    }

    _uploadUrl = await store?.get(_fingerprint);

    if (_uploadUrl == null) {
      return false;
    }
    return true;
  }

  /// Start or resume an upload in chunks of [maxChunkSize] throwing
  /// [ProtocolException] on server error
  upload({
    Function(double)? onProgress,
    Function()? onComplete,
  }) async {
    if (!await resume()) {
      await create();
    }

    // get offset from server
    _offset = await _getOffset();

    int totalBytes = _fileSize as int;

    // start upload
    final client = getHttpClient();

    while (!_pauseUpload && (_offset ?? 0) < totalBytes) {
      final uploadHeaders = Map<String, String>.from({
        "Tus-Resumable": tusVersion,
        "Upload-Offset": "$_offset",
        "Content-Type": "application/offset+octet-stream",
        "Accept": "application/vnd.vimeo.*+json;version=3.4",
      });

      _chunkPatchFuture = client.patch(
        _uploadUrl as Uri,
        headers: uploadHeaders,
        body: await _getData(),
      );

      final response = await _chunkPatchFuture;
      _chunkPatchFuture = null;

      // check if correctly uploaded
      if (!(response!.statusCode >= 200 && response.statusCode < 300)) {
        throw ProtocolException(
            "unexpected status code (${response.statusCode}) while uploading chunk");
      }

      int? serverOffset = _parseOffset(response.headers["upload-offset"]);
      if (serverOffset == null) {
        throw ProtocolException(
            "response to PATCH request contains no or invalid Upload-Offset header");
      }
      if (_offset != serverOffset) {
        throw ProtocolException(
            "response contains different Upload-Offset value ($serverOffset) than expected ($_offset)");
      }

      // update progress
      if (onProgress != null) {
        onProgress((_offset ?? 0) / totalBytes * 100);
      }

      if (_offset == totalBytes) {
        this.onComplete();
        if (onComplete != null) {
          onComplete();
        }
      }
    }
  }

  /// Pause the current upload
  pause() async {
    _pauseUpload = true;
    _chunkPatchFuture?.timeout(Duration.zero, onTimeout: null);
    await deleteVideo();
    _uploadUrl = null;
    _offset = null;
    _vimeoDetails = null;
    _fingerprint = "";
    _processingVideo = false;
    _chunkPatchFuture = null;
  }

  Future deleteVideo() async {
    final client = getHttpClient();
    final createHeaders = {"Authorization": "Bearer $token"};
    String videoId = jsonDecode(_vimeoDetails!.body)['uri'];
    videoId = videoId.substring(videoId.lastIndexOf('/'));
    final response = await client.delete(
      Uri.parse("https://api.vimeo.com/videos/$videoId"),
      headers: createHeaders,
    );
    print(response.statusCode);
    if (!(response.statusCode >= 200 && response.statusCode < 300) &&
        response.statusCode != 404) {
      throw ProtocolException(
          "unexpected status code (${response.statusCode}) while moving video");
    }
  }

  Future<bool> moveVideoToFolder({required String folderId}) async {
    if (_vimeoDetails != null) {
      final client = getHttpClient();
      final createHeaders = {"Authorization": "Bearer $token"};
      String videoId = jsonDecode(_vimeoDetails!.body)['uri'];
      videoId = videoId.substring(videoId.lastIndexOf('/'));
      final response = await client.put(
        Uri.parse(
            "https://api.vimeo.com/me/projects/$folderId/videos/$videoId"),
        headers: createHeaders,
      );
      if (!(response.statusCode >= 200 && response.statusCode < 300) &&
          response.statusCode != 404) {
        throw ProtocolException(
            "unexpected status code (${response.statusCode}) while moving video");
      }
      return true;
    }
    return false;
  }

  Future<String?> getVideoHLSlink() async {
    String? videoUrl;
    if (_vimeoDetails != null) {
      final client = getHttpClient();
      final createHeaders = {"Authorization": "Bearer $token"};
      String videoId = jsonDecode(_vimeoDetails!.body)['uri'];
      videoId = videoId.substring(videoId.lastIndexOf('/'));
      final response = await client.get(
        Uri.parse("https://api.vimeo.com/videos/$videoId"),
        headers: createHeaders,
      );
      if (!(response.statusCode >= 200 && response.statusCode < 300) &&
          response.statusCode != 404) {
        throw ProtocolException(
            "unexpected status code (${response.statusCode}) while retriving video url");
      }
      final res = jsonDecode(response.body);
      while (res['status'] != "available") {
        _processingVideo = true;
        await Future.delayed(Duration(seconds: 10));
        return getVideoHLSlink();
      }
      videoUrl = res['files'].firstWhere((e) => e['quality'] == "hls")['link'];
      _processingVideo = false;
    }
    return videoUrl;
  }

  /// Actions to be performed after a successful upload
  void onComplete() {
    store?.remove(_fingerprint);
  }

  /// Override this method to customize creating file fingerprint
  String? generateFingerprint() {
    return file.path.replaceAll(RegExp(r"\W+"), '.');
  }

  /// Get offset from server throwing [ProtocolException] on error
  Future<int> _getOffset() async {
    final client = getHttpClient();

    final offsetHeaders = Map<String, String>.from({
      "Tus-Resumable": tusVersion,
      "Accept": "application/vnd.vimeo.*+json;version=3.4",
    });

    final response =
        await client.head(_uploadUrl as Uri, headers: offsetHeaders);

    if (!(response.statusCode >= 200 && response.statusCode < 300)) {
      throw ProtocolException(
          "unexpected status code (${response.statusCode}) while resuming upload");
    }

    int? serverOffset = _parseOffset(response.headers["upload-offset"]);
    if (serverOffset == null) {
      throw ProtocolException(
          "missing upload offset in response for resuming upload");
    }
    return serverOffset;
  }

  /// Get data from file to upload

  Future<Uint8List> _getData() async {
    int start = _offset ?? 0;
    int end = (_offset ?? 0) + maxChunkSize;
    end = end > (_fileSize ?? 0) ? _fileSize ?? 0 : end;

    final result = BytesBuilder();
    await for (final chunk in file.openRead(start, end)) {
      result.add(chunk);
    }

    final bytesRead = min(maxChunkSize, result.length);
    _offset = (_offset ?? 0) + bytesRead;

    return result.takeBytes();
  }

  int? _parseOffset(String? offset) {
    if (offset == null || offset.isEmpty) {
      return null;
    }
    if (offset.contains(",")) {
      offset = offset.substring(0, offset.indexOf(","));
    }
    return int.tryParse(offset);
  }

  Uri _parseUrl(String urlStr) {
    if (urlStr.contains(",")) {
      urlStr = urlStr.substring(0, urlStr.indexOf(","));
    }
    Uri uploadUrl = Uri.parse(urlStr);
    if (uploadUrl.host.isEmpty) {
      uploadUrl = uploadUrl.replace(host: url.host, port: url.port);
    }
    if (uploadUrl.scheme.isEmpty) {
      uploadUrl = uploadUrl.replace(scheme: url.scheme);
    }
    return uploadUrl;
  }
}
