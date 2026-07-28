PACKAGES = RenderCore AudioPipeline ProjectStore Recording

gen:
	xcodegen

build: gen
	xcodebuild -project OpenCharm.xcodeproj -scheme OpenCharm -configuration Debug build CODE_SIGNING_ALLOWED=NO

test:
	@for p in $(PACKAGES); do \
		echo "== swift test $$p =="; \
		swift test --package-path Packages/$$p || exit 1; \
	done

format:
	swiftformat .
