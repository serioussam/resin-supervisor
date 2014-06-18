module.exports = config =
	apiEndpoint: process.env.API_ENDPOINT
	registryEndpoint: process.env.REGISTRY_ENDPOINT
	pubnub:
		subscribe_key: process.env.PUBNUB_SUBSCRIBE_KEY
		publish_key: process.env.PUBNUB_PUBLISH_KEY
	mixpanelToken: process.env.MIXPANEL_TOKEN
	dockerSocket: '/run/docker.sock'
	expectedEnvVars: [
		'API_ENDPOINT'
		'REGISTRY_ENDPOINT'
		'MIXPANEL_TOKEN'
		'PUBNUB_SUBSCRIBE_KEY'
		'PUBNUB_PUBLISH_KEY'
	]

# A check that all variables are set and notify the user if not
for envVar in config.expectedEnvVars when !process.env[envVar]?
	console.error('Cannot find env var:', envVar)

