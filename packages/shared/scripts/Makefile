.PHONY: local-build-base-template
local-build-base-template:
	echo "Building base template for local dev..."
	npm install
	DOTENV_CONFIG_PATH=./.env.local \
		npx tsx \
			--import dotenv/config \
			build.prod.ts

.PHONY: local-build-base-128m-template
local-build-base-128m-template:
	echo "Building base-128m template (128 MB RAM) for local dev..."
	npm install
	DOTENV_CONFIG_PATH=./.env.local \
		npx tsx \
			--import dotenv/config \
			build-128m.ts
