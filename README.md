# Udara CLI (Private)

A self-contained tool to manage and build Flutter projects for different clients.

---

## Installation 📦

This is a private repository. To install the CLI, you must have access to this repository and authenticate using SSH (recommended) or a Personal Access Token.

### Using SSH (Recommended)

Make sure you have [added your SSH key to your GitHub account](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account).

```bash
dart pub global activate --source git git@github.com:your-username/udara_cli.git
```

### Using a Personal Access Token (PAT)

[Generate a PAT](https://github.com/settings/tokens/new) with the `repo` scope.

```bash
dart pub global activate --source git https://<YOUR_TOKEN>@[github.com/your-username/udara_cli.git](https://github.com/your-username/udara_cli.git)
```
