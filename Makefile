PACKAGES = RenderCore AudioPipeline ProjectStore Recording

.PHONY: fetch-model gen build test format dist run

# Downloads + checksum-verifies the RNNoise model weights (rnnoise_data.c,
# ~74 MB, not committed to git). Idempotent: no-ops if already present and
# verified. See Tools/fetch-rnnoise-model.sh.
fetch-model:
	Tools/fetch-rnnoise-model.sh

gen: fetch-model
	xcodegen

build: gen
	xcodebuild -project OpenCharm.xcodeproj -scheme OpenCharm -configuration Debug build CODE_SIGNING_ALLOWED=NO

test: fetch-model
	@for p in $(PACKAGES); do \
		echo "== swift test $$p =="; \
		swift test --package-path Packages/$$p || exit 1; \
	done

format:
	swiftformat .

# Release build copied to dist/OpenCharm.app.
dist:
	Tools/build-dist.sh

# Rebuild dist and relaunch it: quits any running copy first (graceful — the
# unsaved-work prompt still appears if a Studio project has pending changes).
run: dist
	@osascript -e 'tell application "OpenCharm" to quit' >/dev/null 2>&1 || true
	@sleep 1
	open dist/OpenCharm.app
