Promise = require 'bluebird'
m = require 'mochainon'
{ expect } = m.chai
conversions = require '../src/lib/conversions'

appDBFormat = {
	appId: '1234' 
	commit: 'bar'
	buildId: '2'
	name: 'app'
	services: JSON.stringify([
		{
			appId: '1234'
			serviceId: '4'
			serviceName: 'serv'
			environment: { FOO: 'var2' }
			labels: {}
			config: {}
			image: 'foo/bar'
		}
	])
	config: JSON.stringify({ RESIN_FOO: 'var' })
}

appDBFormatWithNetworksAndVolumes = {
	appId: '1234' 
	commit: 'bar'
	buildId: '2'
	name: 'app'
	services: JSON.stringify([
		{
			appId: '1234'
			serviceId: '4'
			serviceName: 'serv'
			environment: { FOO: 'var2' }
			labels: {}
			config: {}
			image: 'foo/bar'
		}
	])
	networks: "{}"
	volumes: "{}"
	config: JSON.stringify({ RESIN_FOO: 'var' })
}

appStateFormat = {
	appId: '1234' 
	commit: 'bar'
	buildId: '2'
	name: 'app'
	services: [
		{
			appId: '1234'
			serviceId: '4'
			serviceName: 'serv'
			environment: { FOO: 'var2' }
			labels: {}
			config: {}
			image: 'foo/bar'
		}
	]
	config: { RESIN_FOO: 'var' }
}

appStateFormatWithDefaults = {
	appId: '1234' 
	commit: 'bar'
	buildId: '2'
	name: 'app'
	services: [
		{
			appId: '1234'
			environment: {
				FOO: 'var2'
				RESIN: '1'
				RESIN_API_KEY: 'anothersecret'
				RESIN_APP_BUILD: '2'
				RESIN_APP_ID: '1234'
				RESIN_APP_NAME: 'app'
				RESIN_APP_RELEASE: 'bar'
				RESIN_DEVICE_NAME_AT_INIT: 'devicename'
				RESIN_DEVICE_TYPE: 'amazing-board'
				RESIN_DEVICE_UUID: 'foo'
				RESIN_HOST_OS_VERSION: 'Resin OS 2.1.1'
				RESIN_SERVICE_NAME: 'serv'
				RESIN_SUPERVISOR_ADDRESS: 'http://127.0.0.1:8080'
				RESIN_SUPERVISOR_API_KEY: 'secret'
				RESIN_SUPERVISOR_HOST: '127.0.0.1'
				RESIN_SUPERVISOR_PORT: '8080'
				RESIN_SUPERVISOR_VERSION: '6.1.3'
				USER: "root"
			}
			labels: {}
			config: {}
			serviceId: '4'
			serviceName: 'serv'
			image: 'foo/bar:latest'
			privileged: false
			restartPolicy: {
				Name: 'unless-stopped'
			}
			volumes: [
				'/resin-data/1234/services/4:/data'
				'/tmp/resin-supervisor/1234:/tmp/resin'
			]
			running: true

		}
	]
	networks: {}
	volumes: {}
	config: { RESIN_FOO: 'var' }
}

dependentStateFormat = {
	appId: '1234'
	image: 'foo/bar'
	commit: 'bar'
	buildId: '3'
	name: 'app'
	config: { RESIN_FOO: 'var' }
	environment: { FOO: 'var2' }
	parentApp: '256'
}


dependentDBFormat = {
	appId: '1234' 
	image: 'foo/bar'
	commit: 'bar'
	buildId: '3'
	name: 'app'
	config: JSON.stringify({ RESIN_FOO: 'var' })
	environment: JSON.stringify({ FOO: 'var2' })
	parentApp: '256'
}

describe 'conversions', ->
	describe 'state to DB', ->
		it 'converts an app from a state format to a db format, adding missing networks and volumes', ->
			app = conversions.appStateToDB(appStateFormat)
			expect(app).to.deep.equal(appDBFormatWithNetworksAndVolumes)

		it 'converts a dependent app from a state format to a db format', ->
			app = conversions.dependentAppStateToDB(dependentStateFormat)
			expect(app).to.deep.equal(dependentDBFormat)

	describe 'DB to state', ->
		it 'converts an app in DB format into state format, adding default and missing fields', ->
			appConversion = conversions.appDBToStateAsync({
				uuid: 'foo'
				listenPort: '8080'
				apiSecret: 'secret'
				deviceApiKey: 'anothersecret'
				version: '6.1.3'
				deviceType: 'amazing-board'
				osVersion: 'Resin OS 2.1.1'
				name: 'devicename'
			}, { normalise: (i) -> Promise.resolve(i + ':latest') })
			promise = appConversion(appDBFormatWithNetworksAndVolumes)
			expect(promise).to.eventually.deep.equal(appStateFormatWithDefaults)

		it 'converts a dependent app in DB format into state format', ->
			app = conversions.dependentAppDBToState(dependentDBFormat)
			expect(app).to.deep.equal(dependentStateFormat)
