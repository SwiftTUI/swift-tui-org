Bazel does not really complicate the squash. The important part is Git submodules.

  Bazel uses local_path_override(...), so it reads whatever source is checked out at swift-tui/, swift-tui-web/, etc. It does not care about commit ancestry. The
  orchestration root, however, records each child repo as a submodule gitlink, and those gitlinks are exact commit hashes. When you squash a child repo, every commit hash
  changes, so the root repo must be repinned afterward.

  Recommended order:

  1. Freeze the current integrated state.

     cd /Users/adamz/Developer/SwiftTUI/swift-tui-org
     npx @bazel/bazelisk@latest test //:org
     git submodule status --recursive

  2. For each child repo, create a private backup of old history, then replace main with a single orphan commit.

     cd /Users/adamz/Developer/SwiftTUI/swift-tui

     git switch main
     git pull --ff-only

     git tag private/pre-public-history-2026-05-24
     git switch --orphan public-main

     git add -A
     git commit -m "Initial public release"

     git branch -M main
     git push --force-with-lease origin main

     Do this for swift-tui, swift-tui-web, swift-tui-examples, and swift-tui-site.

     I would keep the old-history backup private, not as a public branch/tag, if the point is a clean first public history.

  3. Re-pin the orchestration root after all child repos are rewritten.

     cd /Users/adamz/Developer/SwiftTUI/swift-tui-org

     git submodule update --remote --merge swift-tui
     git submodule update --remote --merge swift-tui-web
     git submodule update --remote --merge swift-tui-examples
     git submodule update --remote --merge swift-tui-site

     git status
     git add swift-tui swift-tui-web swift-tui-examples swift-tui-site
     git commit -m "chore: pin squashed public repo histories"

  4. Verify Bazel after repinning.

     npx @bazel/bazelisk@latest fetch //:org
     npx @bazel/bazelisk@latest test //:org

  5. Then squash the orchestration root itself, last.

     The root’s single public commit should contain the final submodule gitlinks pointing at the new squashed child commits.

     cd /Users/adamz/Developer/SwiftTUI/swift-tui-org

     git switch --orphan public-main
     git add -A
     git commit -m "Initial SwiftTUI organization workspace"

     git branch -M main
     git push --force-with-lease origin main

  6. Recreate release tags after the rewrite.

     Do not preserve old release tags that point into pre-squash history. For SwiftPM, tags on SwiftTUI/swift-tui are the public contract, so create the first public tag
     only after the squashed main is final:

     cd /Users/adamz/Developer/SwiftTUI/swift-tui
     git tag v0.1.0
     git push origin v0.1.0

  One public-facing detail: if swift-tui-org will itself be public, consider changing .gitmodules URLs from SSH to HTTPS before the final root squash. git@github.com:...
  is fine for maintainers, but https://github.com/SwiftTUI/... makes git clone --recurse-submodules work for public read-only users without SSH setup.
