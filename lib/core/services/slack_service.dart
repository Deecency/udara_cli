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

  String? _channelId;

  void _debugLog(String message) {
    if (debugMode || Logger.verbose) {
      Logger.info('[Slack Debug] $message');
    }
  }

  /// Test the Slack connection with detailed feedback
  Future<bool> testConnection() async {
    try {
      _debugLog('Testing connection with token: ${_maskToken(botToken)}');
      final url = Uri.parse('https://slack.com/api/auth.test');

      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $botToken',
          'Content-Type': 'application/json',
        },
      );

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
    try {
      _debugLog('Sending message to channel: $channel');
      _debugLog('Message: $message');

      final url = Uri.parse('https://slack.com/api/chat.postMessage');

      final payload = {
        'channel': channel,
        'text': message,
        if (emoji != null) 'icon_emoji': emoji,
      };

      _debugLog('Payload: ${jsonEncode(payload)}');

      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $botToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );

      _debugLog('Message response status: ${response.statusCode}');
      _debugLog('Message response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final success = data['ok'] as bool? ?? false;

        if (!success) {
          final error = data['error'] as String? ?? 'Unknown error';
          Logger.warning('Failed to send Slack message: $error');

          // Provide helpful error messages
          switch (error) {
            case 'channel_not_found':
              Logger.info('Channel "$channel" not found. Suggestions:');
              Logger.info('  • Verify the channel exists');
              Logger.info('  • Ensure the bot is added to the channel');
              Logger.info(
                  '  • Use channel ID instead of name if channel is private');
              break;
            case 'not_in_channel':
              Logger.info(
                  'Bot is not in channel "$channel". Add the bot to the channel first.');
              break;
            case 'invalid_auth':
              Logger.info(
                  'Invalid bot token. Run "udara_cli setup --notify" to reconfigure.');
              break;
          }
        } else {
          _debugLog('Message sent successfully');
        }

        return success;
      }

      Logger.warning(
          'HTTP error sending Slack message: ${response.statusCode}');
      return false;
    } catch (e) {
      _debugLog('Exception sending message: $e');
      Logger.warning('Failed to send Slack message: $e');
      return false;
    }
  }

  /// Send a rich message with attachments/blocks
  Future<bool> sendRichMessage({
    required String title,
    required String message,
    String color = 'good', // good, warning, danger, or hex color
    Map<String, String>? fields,
    String? emoji,
  }) async {
    try {
      _debugLog('Sending rich message to channel: $channel');

      final url = Uri.parse('https://slack.com/api/chat.postMessage');

      final attachment = {
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
        'attachments': [attachment],
        if (emoji != null) 'icon_emoji': emoji,
      };

      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $botToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );

      _debugLog('Rich message response: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final success = data['ok'] as bool? ?? false;

        _channelId ??= data['channel'] as String?;

        if (!success) {
          Logger.warning('Failed to send rich Slack message: ${data['error']}');
        }

        return success;
      }

      return false;
    } catch (e) {
      _debugLog('Exception sending rich message: $e');
      Logger.warning('Failed to send rich Slack message: $e');
      return false;
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
      };

      if (comment != null) {
        requestBody['initial_comment'] = comment;
      }

      final response = await http.post(
        Uri.parse('https://slack.com/api/files.completeUploadExternal'),
        headers: {
          'Authorization': 'Bearer $botToken',
          'Content-Type': 'application/json',
        },
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
      'Platform': platform,
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

  /// Send build completion summary
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
    _debugLog('File exists: ${artifactFile?.existsSync() ?? false}');

    final fields = <String, String>{
      'Client': client,
      'Platform': platform,
      'Type': type.toUpperCase(),
      'Version': version,
      'Build Time': '${buildTime.inMinutes}m ${buildTime.inSeconds % 60}s',
      'Status': success ? 'SUCCESS' : 'FAILED',
    };

    if (errorMessage != null) {
      fields['Error'] = errorMessage;
    }

    // Upload artifact if it's an APK and build was successful
    if (success && type.toLowerCase() == 'apk' && artifactFile != null) {
      Logger.info('Uploading APK artifact to Slack...');

      final uploadSuccess = await uploadFile(
        file: artifactFile,
        title: '📱 ${client}_$version.apk',
        comment: 'Fresh build ready for testing! 🚀\n\n'
            '• Client: $client\n'
            '• Version: $version\n'
            '• Platform: $platform\n'
            '• Build time: ${buildTime.inMinutes}m ${buildTime.inSeconds % 60}s',
      );

      if (uploadSuccess) {
        Logger.success('APK uploaded to Slack successfully!');
      } else {
        Logger.warning('Failed to upload APK artifact to Slack.');
      }
    } else {
      _debugLog('Skipping APK upload:');
      _debugLog('  - Success: $success');
      _debugLog('  - Type is APK: ${type.toLowerCase() == 'apk'}');
      _debugLog('  - File provided: ${artifactFile != null}');

      if (success && type.toLowerCase() != 'apk') {
        Logger.info(
            'APK upload skipped — build type is "$type" (only APKs are uploaded)');
      } else if (!success) {
        Logger.info('APK upload skipped — build was not successful.');
      } else if (artifactFile == null) {
        Logger.warning('APK upload skipped — no artifact file provided.');
      }
    }
  }

  String _maskToken(String token) {
    if (token.length <= 8) return '***';
    return '${token.substring(0, 8)}...${token.substring(token.length - 4)}';
  }
}
