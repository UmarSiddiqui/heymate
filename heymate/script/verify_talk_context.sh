#!/bin/bash
# Pure production policy checks. No GUI, accounts, audio devices or capture.
set -euo pipefail
cd "$(dirname "$0")/.."
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/heymate-talk-context.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  HeyMate/SpokenText.swift HeyMate/VoiceRouter.swift HeyMate/AgentInvocation.swift \
  HeyMate/LocalVoiceAction.swift HeyMate/SystemVolume.swift HeyMate/PushToTalkShortcut.swift \
  HeyMate/TalkContextPolicy.swift HeyMate/SpeechText.swift script/talk_context_probe.swift \
  -o "$probe_dir/probe"
"$probe_dir/probe"
