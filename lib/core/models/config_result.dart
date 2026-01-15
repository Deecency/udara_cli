/// A helper class to hold the result of a configuration cleanup operation.
class ConfigCleanupResult {
  final List<String> lines;
  final bool modified;

  ConfigCleanupResult(this.lines, this.modified);
}

/// A helper class to hold the result of a configuration file creation operation.
class ConfigCreationResult {
  final bool created;

  ConfigCreationResult(this.created);
}
