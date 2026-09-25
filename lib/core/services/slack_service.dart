import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import '../core.dart';

class SlackService {
  final String botToken;
  final String channel;
  final bool debugMode;

  SlackService({
    required this.botToken,
    required this.channel,
    this.debugMode = false,
  });

  /// Resolved channel ID, learned from the first successful post. Needed by
  /// the file upload API, which does not accept channel names.
  String? _channelId;

  void _debugLog(String message) {
    if (debugMode || Logger.verbose) {
      Logger.info('[Slack Debug] $message');
    }
  }

  Map<String, String> get _jsonHeaders => {
        'Authorization': 'Bearer $botToken',
        'Content-Type': 'application/json',
      };

  /// Test the Slack connection with detailed feedback
  Future<bool> testConnection() async {
    try {
      _debugLog('Testing connection with token: ${_maskToken(botToken)}');
      final url = Uri.parse('https://slack.com/api/auth.test');

      final response = await http.post(url, headers: _jsonHeaders);

      _debugLog('Auth test response status: ${response.statusCode}');
      _debugLog('Auth test response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final isOk = data['ok'] as bool? ?? false;

        if (isOk) {
          _debugLog('Authentication successful');
          _debugLog('Bot user: ${data['user']}');
          _debugLog('Team: ${data['team']}');
        } else {
          _debugLog('Authentication failed: ${data['error']}');
        }

        return isOk;
      }
      return false;
    } catch (e) {
      _debugLog('Connection test error: $e');
      return false;
    }
  }

  /// Send a simple text message to Slack
  Future<bool> sendMessage(String message, {String? emoji}) async {
    final payload = {
      'channel': channel,
      'text': message,
      if (emoji != null) 'icon_emoji': emoji,
    };
    return _postMessage(payload, label: 'message');
  }

  /// Send a rich message with attachments/blocks
  Future<bool> sendRichMessage({
    required String title,
    required String message,
    String color = 'good', // good, warning, danger, or hex color
    Map<String, String>? fields,
    String? emoji,
  }) async {
    final attachment = <String, dynamic>{
      'color': color,
      'title': title,
      'text': message,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };

    if (fields != null && fields.isNotEmpty) {
      attachment['fields'] = fields.entries
          .map((e) => {
                'title': e.key,
                'value': e.value,
                'short': true,
              })
          .toList();
    }

    final payload = {
      'channel': channel,
      'text': title,
      'attachments': [attachment],
      if (emoji != null) 'icon_emoji': emoji,
    };
    return _postMessage(payload, label: 'rich message');
  }

  Future<bool> _postMessage(Map<String, dynamic> payload,
      {required String label}) async {
    try {
      _debugLog('Sending $label to channel: $channel');
      _debugLog('Payload: ${jsonEncode(payload)}');

      final response = await http.post(
        Uri.parse('https://slack.com/api/chat.postMessage'),
        headers: _jsonHeaders,
        body: jsonEncode(payload),
      );

      _debugLog('Response status: ${response.statusCode}');
      _debugLog('Response body: ${response.body}');

      if (response.statusCode != 200) {
        Logger.warning(
            'HTTP error sending Slack $label: ${response.statusCode}');
        return false;
      }

      final data = jsonDecode(response.body);
      final success = data['ok'] as bool? ?? false;

      if (success) {
        _channelId ??= data['channel'] as String?;
        _debugLog('$label sent successfully');
        return true;
      }

      final error = data['error'] as String? ?? 'Unknown error';
      Logger.warning('Failed to send Slack $label: $error');
      _explainError(error);
      return false;
    } catch (e) {
      _debugLog('Exception sending $label: $e');
      Logger.warning('Failed to send Slack $label: $e');
      return false;
    }
  }

  void _explainError(String error) {
    switch (error) {
      case 'channel_not_found':
        Logger.info('Channel "$channel" not found. Suggestions:');
        Logger.info('  • Verify the channel exists');
        Logger.info('  • Ensure the bot is added to the channel');
        Logger.info('  • Use channel ID instead of name if channel is private');
        break;
      case 'not_in_channel':
        Logger.info(
            'Bot is not in channel "$channel". Add the bot to the channel first.');
        break;
      case 'invalid_auth':
      case 'token_revoked':
        Logger.info(
            'Invalid bot token. Run "udara_cli setup --notify" to reconfigure.');
        break;
      case 'missing_scope':
        Logger.info(
            'Bot token is missing a scope. Required: chat:write, files:write, channels:read.');
        break;
    }
  }

  /// Upload a file to Slack using the three-step external upload process
  Future<bool> uploadFile({
    required File file,
    String? title,
    String? comment,
  }) async {
    try {
      _debugLog('Starting file upload: ${file.path}');

      if (_channelId == null) {
        Logger.warning(
            'Cannot share file: Slack channel ID is unknown. Send a message first.');
        return false;
      }

      // Step 1: Get upload URL and file ID from Slack
      final uploadInfo = await _getUploadUrl(file);
      if (uploadInfo == null) {
        Logger.warning('Failed to obtain upload URL from Slack.');
        return false;
      }

      _debugLog('Got upload URL and file ID');

      // Step 2: Upload file to the provided URL
      final uploadSuccess = await _uploadToUrl(file, uploadInfo);
      if (!uploadSuccess) {
        Logger.warning('Failed to upload file content to Slack S3 URL.');
        return false;
      }

      _debugLog('File uploaded to URL successfully');

      // Step 3: Complete the upload and post to channel
      final success = await _completeUpload(
        fileId: uploadInfo['file_id'],
        title: title,
        comment: comment,
      );

      if (success) {
        Logger.success('File uploaded to Slack successfully.');
      } else {
        Logger.warning('Failed to complete file upload on Slack.');
      }

      return success;
    } catch (e) {
      _debugLog('Exception during file upload: $e');
      Logger.warning('Failed to upload file to Slack: $e');
      return false;
    }
  }

  /// Step 1: Get upload URL from Slack
  Future<Map<String, dynamic>?> _getUploadUrl(File file) async {
    try {
      final fileStats = await file.stat();
      final fileName = path.basename(file.path);

      _debugLog(
          'Requesting upload URL for file: $fileName (${fileStats.size} bytes)');

      final response = await http.post(
        Uri.parse('https://slack.com/api/files.getUploadURLExternal'),
        headers: {
          'Authorization': 'Bearer $botToken',
        },
        body: {
          'filename': fileName,
          'length': fileStats.size.toString(),
        },
      );

      final responseBody = response.body;
      _debugLog('Upload URL response: $responseBody');

      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody);
        if (data['ok'] == true) {
          return {
            'upload_url': data['upload_url'],
            'file_id': data['file_id'],
          };
        } else {
          final error = data['error'] ?? 'Unknown error';
          _debugLog('Slack API error getting upload URL: $error');
          Logger.warning('Slack API error getting upload URL: $error');
        }
      } else {
        _debugLog('HTTP error getting upload URL: ${response.statusCode}');
        Logger.warning('HTTP error getting upload URL: ${response.statusCode}');
      }

      return null;
    } catch (e) {
      _debugLog('Exception getting upload URL: $e');
      return null;
    }
  }

  /// Step 2: Upload file to the provided URL
  Future<bool> _uploadToUrl(File file, Map<String, dynamic> uploadInfo) async {
    try {
      final uploadUrl = uploadInfo['upload_url'] as String;

      _debugLog('Uploading file to: $uploadUrl');
      final fileBytes = await file.readAsBytes();

      final response = await http.post(
        Uri.parse(uploadUrl),
        headers: {
          'Content-Type': 'application/octet-stream',
        },
        body: fileBytes,
      );

      _debugLog('File upload to URL response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        return true;
      } else {
        _debugLog('Failed to upload to URL: ${response.statusCode}');
        _debugLog('Response body: ${response.body}');
        return false;
      }
    } catch (e) {
      _debugLog('Exception uploading to URL: $e');
      return false;
    }
  }

  /// Step 3: Complete the upload process and post to channel
  Future<bool> _completeUpload({
    required String fileId,
    String? title,
    String? comment,
  }) async {
    try {
      _debugLog('Completing upload for file ID: $fileId');

      final requestBody = <String, dynamic>{
        'files': [
          {
            'id': fileId,
            if (title != null) 'title': title,
          }
        ],
        'channel_id': _channelId,
        if (comment != null) 'initial_comment': comment,
      };

      final response = await http.post(
        Uri.parse('https://slack.com/api/files.completeUploadExternal'),
        headers: _jsonHeaders,
        body: jsonEncode(requestBody),
      );

      final responseBody = response.body;
      _debugLog('Complete upload response: $responseBody');

      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody);
        final success = data['ok'] as bool? ?? false;

        if (!success) {
          final error = data['error'] ?? 'Unknown error';
          _debugLog('Slack API error completing upload: $error');
          Logger.warning('Slack API error completing upload: $error');
        }

        return success;
      } else {
        _debugLog('HTTP error completing upload: ${response.statusCode}');
        Logger.warning('HTTP error completing upload: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      _debugLog('Exception completing upload: $e');
      return false;
    }
  }

  /// Send build step notification
  Future<void> sendBuildStepNotification({
    required String step,
    required String client,
    required String platform,
    required String status, // started, completed, failed
    String? additionalInfo,
    String? errorMessage,
  }) async {
    String emoji;
    String color;
    String message;

    switch (status.toLowerCase()) {
      case 'started':
        emoji = ':rocket:';
        color = '#36a64f'; // green
        message = 'Build step started';
        break;
      case 'completed':
        emoji = ':white_check_mark:';
        color = 'good';
        message = 'Build step completed successfully';
        break;
      case 'failed':
        emoji = ':x:';
        color = 'danger';
        message = 'Build step failed';
        break;
      default:
        emoji = ':information_source:';
        color = 'warning';
        message = 'Build step update';
    }

    final fields = <String, String>{
      'Client': client,
      if (platform.isNotEmpty) 'Platform': platform,
      'Step': step,
      'Status': status.toUpperCase(),
    };

    if (additionalInfo != null) {
      fields['Info'] = additionalInfo;
    }

    if (errorMessage != null) {
      fields['Error'] = errorMessage;
    }

    final success = await sendRichMessage(
      title: '$emoji Build Update - $step',
      message: message,
      color: color,
      fields: fields,
    );

    if (!success) {
      Logger.warning('Failed to send build step notification for "$step"');
    }
  }

  /// Send build completion summary, then upload the APK when there is one.
  Future<void> sendBuildSummary({
    required String client,
    required String platform,
    required String type,
    required String version,
    required bool success,
    required Duration buildTime,
    String? errorMessage,
    File? artifactFile,
  }) async {
    _debugLog('=== BUILD SUMMARY ===');
    _debugLog('Success: $success');
    _debugLog('Type: $type');
    _debugLog('Artifact file: ${artifactFile?.path ?? 'null'}');

    final duration = '${buildTime.inMinutes}m ${buildTime.inSeconds % 60}s';

    final fields = <String, String>{
      'Client': client,
      'Platform': platform,
      'Type': type.toUpperCase(),
      'Version': version,
      'Build Time': duration,
      'Status': success ? 'SUCCESS' : 'FAILED',
      if (errorMessage != null) 'Error': errorMessage,
      if (artifactFile != null) 'Artifact': path.basename(artifactFile.path),
    };

    final posted = await sendRichMessage(
      title: success
          ? ':white_check_mark: Build Succeeded - $client'
          : ':x: Build Failed - $client',
      message: success
          ? 'The $platform ${type.toUpperCase()} build for "$client" completed in $duration.'
          : 'The $platform build for "$client" failed after $duration.',
      color: success ? 'good' : 'danger',
      fields: fields,
    );
    if (!posted) {
      Logger.warning('Failed to send build summary to Slack.');
    }

    final isApk = type.toLowerCase() == 'apk';
    if (success && isApk && artifactFile != null && artifactFile.existsSync()) {
      Logger.info('Uploading APK artifact to Slack...');

      final uploadSuccess = await uploadFile(
        file: artifactFile,
        title: '📱 ${path.basename(artifactFile.path)}',
        comment: 'Fresh build ready for testing! 🚀\n\n'
            '• Client: $client\n'
            '• Version: $version\n'
            '• Platform: $platform\n'
            '• Build time: $duration',
      );

      if (!uploadSuccess) {
        Logger.warning('Failed to upload APK artifact to Slack.');
      }
    } else if (success && !isApk) {
      Logger.info(
          'Artifact upload skipped — only APKs are uploaded to Slack (build type is "$type").');
    }
  }

  String _maskToken(String token) {
    if (token.length <= 8) return '***';
    return '${token.substring(0, 8)}...${token.substring(token.length - 4)}';
  }
}
