PACKAGES = RenderCore AudioPipeline ProjectStore Recording

.PHONY: fetch-model gen build test format

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
