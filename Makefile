.PHONY: clean-rebuild

clean-rebuild:
	cabal sandbox delete
	cabal sandbox init --sandbox .cabal-sandbox
	cabal sandbox add-source ../diff-parse
	cabal sandbox add-source ../github
	cabal install alex happy
	cabal install --dependencies-only
	cabal install yesod-bin

ngrok:
	ngrok -subdomain=reviewhub 3000

clean-heroku:
	# Clean up the anvil cache
	rm -rf .anvil

	# Enable Anvil builds
	heroku plugins:install https://github.com/ddollar/heroku-anvil

	# Move big build artifacts out of the way or else the upload
	# to Anvil will be very slow
	mkdir -p /tmp/deploy-stash
	mv -n .cabal-sandbox /tmp/deploy-stash || echo "no .cabal-sandbox to archive"
	mv -n dist /tmp/deploy-stash || echo "no dist to archive"

	# Build your slug and cache without any time limits
	heroku build -r -b https://github.com/cpennington/heroku-buildpack-ghc.git

	# Use Anvil-generated cache next time we do a regular git push to Heroku
	heroku config:set EXTERNAL_CACHE=$(cat .anvil/cache)

	# Bring your sandbox etc back
	mv /tmp/deploy-stash/.cabal-sandbox .
	mv /tmp/deploy-stash/dist .

	# Deploy to heroku
	git push HEAD heroku

	# Clean up
	heroku config:unset EXTERNAL_CACHE

cleanup-failed-clean-heroku:
	# Bring your sandbox etc back
	mv /tmp/deploy-stash/.cabal-sandbox .
	mv /tmp/deploy-stash/dist .