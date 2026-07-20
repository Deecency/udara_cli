import 'package:udara_cli/core/core.dart';

class SlackTestCommand extends UdaraCommand {
  SlackTestCommand() {
    argParser.addOption(
      'channel',
      abbr: 'c',
      help: 'Channel to test (e.g., #general, @username)',
      defaultsTo: '#general',
    );
  }

  @override
  final String name = 'slack-test';

  @override
  final String description =
      'Test Slack integration and debug connection issues.';

  @override
  Future<void> run() async {
    final channel = argResults!['channel'] as String;

    Logger.phase('🧪 Testing Slack Integration');

    // Check if Slack is configured
    final slackToken = await ConfigService.getSlackBotToken();
    if (slackToken == null) {
      throw BuildException(
        'Slack bot token is not configured.',
        fix: 'Run "udara_cli setup --notify" to configure your Slack token.',
      );
    }

    Logger.success('Slack token found');
    Logger.info('Target channel: $channel\n');

    final slackService = SlackService(
      botToken: slackToken,
      channel: channel,
      debugMode: true,
    );

    try {
      // Test 1: Authentication
      Logger.info('🔐 Testing authentication...');
      final authSuccess = await slackService.testConnection();

      if (!authSuccess) {
        _printTroubleshootingTips(channel);
        throw BuildException(
          'Slack authentication failed.',
          fix:
              'Check your bot token at https://api.slack.com/apps or re-run "udara_cli setup --notify".',
        );
      }
      Logger.success('Authentication successful\n');

      // Test 2: Simple message
      Logger.info('📝 Sending test message...');
      final messageSuccess = await slackService.sendMessage(
        '🧪 Test message from Udara CLI at ${DateTime.now()}',
        emoji: ':robot_face:',
      );

      if (!messageSuccess) {
        _printTroubleshootingTips(channel);
        throw BuildException(
          'Failed to send test message to channel "$channel".',
          fix: 'Verify channel existence and bot permissions.',
        );
      }
      Logger.success('Simple message sent successfully\n');

      // Test 3: Rich message
      Logger.info('🎨 Sending rich message...');
      final richSuccess = await slackService.sendRichMessage(
        title: '🧪 Rich Message Test',
        message: 'This is a test of rich message formatting',
        color: 'good',
        fields: {
          'Test Type': 'Rich Message',
          'Status': 'Testing',
          'Timestamp': DateTime.now().toString(),
        },
      );

      if (richSuccess) {
        Logger.success('Rich message sent successfully\n');
      } else {
        Logger.warning('Failed to send rich message.\n');
      }

      // Test 4: Build notification simulation
      Logger.info('🚀 Simulating build notification...');
      await slackService.sendBuildStepNotification(
        step: 'Test Build Step',
        client: 'test-client',
        platform: 'android',
        status: 'completed',
        additionalInfo: 'This is a test notification',
      );

      Logger.success('Slack integration test completed successfully!');
      Logger.info(
          'If you received messages in $channel, your Slack integration is working properly.');
    } on BuildException catch (e, s) {
      Logger.error(e.message,
          cause: e.fix, stackTrace: e.originalStackTrace ?? s);
      rethrow;
    } catch (e, s) {
      Logger.error('An unexpected error occurred during Slack testing.',
          cause: e, stackTrace: s);
      rethrow;
    }
  }

  void _printTroubleshootingTips(String channel) {
    Logger.phase('🔧 Troubleshooting Tips');
    Logger.info('1. Channel Issues:');
    Logger.info('   • Make sure channel "$channel" exists');
    Logger.info(
        '   • Add your bot to the channel first (/invite @your-bot-name)');
    Logger.info('   • For private channels, use channel ID instead of name');
    Logger.info('2. Bot Permissions (https://api.slack.com/apps):');
    Logger.info(
        '   • Ensure required scopes: chat:write, files:write, channels:read');
    Logger.info('3. Bot Installation:');
    Logger.info('   • Confirm the bot token starts with "xoxb-"');
  }
}
