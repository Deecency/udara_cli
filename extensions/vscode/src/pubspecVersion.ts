import * as fs from 'fs';
import * as path from 'path';

/** Flutter's pubspec version format: build-name with an optional +build-number. */
export const VERSION_PATTERN = /^\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?(?:\+\d+)?$/;

const VERSION_LINE = /^(version:[ \t]*)(["']?)([^"'\s#]+)\2(.*)$/m;

export function pubspecPath(root: string): string {
  return path.join(root, 'pubspec.yaml');
}

/** Reads the `version:` value from pubspec.yaml, or undefined when absent. */
export function readPubspecVersion(root: string): string | undefined {
  const file = pubspecPath(root);
  if (!fs.existsSync(file)) {
    return undefined;
  }
  return VERSION_LINE.exec(fs.readFileSync(file, 'utf8'))?.[3];
}

/**
 * Resolves what the user typed into the version to write. A version without
 * a build number keeps the current one, so "1.4.0" on "1.3.9+41" becomes
 * "1.4.0+41". Returns undefined for an empty input (keep the pubspec value).
 */
export function resolveVersion(input: string, current: string | undefined): string | undefined {
  const trimmed = input.trim();
  if (!trimmed) {
    return undefined;
  }
  if (trimmed.includes('+') || !current?.includes('+')) {
    return trimmed;
  }
  return `${trimmed}+${current.split('+')[1]}`;
}

/** Rewrites only the value of the `version:` line, keeping quotes and comments. */
export function replaceVersionInContent(content: string, version: string): string {
  if (!VERSION_LINE.test(content)) {
    throw new Error('pubspec.yaml has no "version:" line to override.');
  }
  return content.replace(
    VERSION_LINE,
    (_m, prefix: string, quote: string, _old: string, rest: string) =>
      `${prefix}${quote}${version}${quote}${rest}`,
  );
}

export function writePubspecVersion(root: string, version: string): void {
  const file = pubspecPath(root);
  fs.writeFileSync(file, replaceVersionInContent(fs.readFileSync(file, 'utf8'), version));
}
