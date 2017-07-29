Promise = require 'bluebird'
Knex = require 'knex'

constants = require './lib/constants'

module.exports = class DB
	constructor: ({ databasePath } = {}) ->
		@knex = Knex(
			client: 'sqlite3'
			connection:
				filename: databasePath ? constants.databasePath
			useNullAsDefault: true
		)

	addColumn: (table, column, type) =>
		@knex.schema.hasColumn(table, column)
		.then (exists) =>
			if not exists
				@knex.schema.table table, (t) ->
					t[type](column)

	dropColumn: (table, column) =>
		@knex.schema.hasColumn(table, column)
		.then (exists) =>
			if exists
				@knex.schema.table table, (t) ->
					t.dropColumn(column)

	dropTableIfExists: (tableName, trx) =>
		knex = trx ? @knex
		knex.schema.hasTable(tableName)
		.then (exists) ->
			knex.schema.dropTable(tableName) if exists

	migrateToV2: =>
		# Drop all tables, but keep the info we need
		@transaction (trx) =>
			trx.schema.hasTable('legacyData')
			.then (exists) =>
				if not exists
					trx.schema.createTable 'legacyData', (t) ->
						t.json('apps')
						t.json('dependentApps')
						t.json('dependentDevices')
					.then =>
						Promise.join(
							trx.schema.hasTable('app')
							.then (exists) ->
								if exists
									trx.select().from('app')
								else
									return []
							.then(JSON.stringify)
							trx.schema.hasTable('dependentDevice')
							.then (exists) ->
								if exists
									trx.select().from('dependentDevice')
								else
									return []
							.then(JSON.stringify)
							trx.schema.hasTable('dependentApp')
							.then (exists) ->
								if exists
									trx.select().from('dependentApp')
								else
									return []
							.then(JSON.stringify)
							(apps, dependentDevices, dependentApps) =>
								@upsertModel('legacyData', { apps, dependentDevices, dependentApps }, {}, trx)
						)
			.then =>
				@dropTableIfExists('app', trx)
			.then =>
				@dropTableIfExists('deviceConfig', trx)
			.then =>
				@dropTableIfExists('dependentApp', trx)
			.then =>
				@dropTableIfExists('dependentDevice', trx)
			.then =>
				@dropTableIfExists('image', trx)
			.then =>
				@dropTableIfExists('container', trx)

	finishMigration: =>
		@transaction (trx) =>
			@upsertModel('config', { key: 'schema-version', value: '2' }, { key: 'schema-version' }, trx)
			.then =>
				@dropTableIfExists('legacyData', trx)

	initConfigAndGetSchemaVersion: =>
		@knex.schema.hasTable('config')
		.then (exists) =>
			if not exists
				@knex.schema.createTable 'config', (t) ->
					t.string('key').primary()
					t.string('value')
				.then =>
					@knex('config').insert({ key: 'schema-version', value: '2' })
				.then ->
					return '2'
			else
				@knex('config').where({ key: 'schema-version' }).select()
				.then ([ schemaVersion ]) ->
					return schemaVersion

	init: =>
		migrationNeeded = false
		@initConfigAndGetSchemaVersion()
		.then (schemaVersion) =>
			if !schemaVersion? or schemaVersion.value != '2'
				# We're on an old db, need to migrate
				migrationNeeded = true
				@migrateToV2()
		.then =>
			Promise.all([
				@knex.schema.hasTable('deviceConfig')
				.then (exists) =>
					if not exists
						@knex.schema.createTable 'deviceConfig', (t) ->
							t.json('targetValues')
				.then =>
					@knex('deviceConfig').select()
					.then (deviceConfigs) =>
						@knex('deviceConfig').insert({ targetValues: '{}' }) if deviceConfigs.length == 0

				@knex.schema.hasTable('app')
				.then (exists) =>
					if not exists
						@knex.schema.createTable 'app', (t) ->
							t.increments('id').primary()
							t.string('name')
							t.string('buildId')
							t.string('commit')
							t.string('appId')
							t.json('config')
							t.json('services')
							t.json('networks')
							t.json('volumes')

				@knex.schema.hasTable('dependentAppTarget')
				.then (exists) =>
					if not exists
						@knex.schema.createTable 'dependentAppTarget', (t) ->
							t.increments('id').primary()
							t.string('appId')
							t.string('parentApp')
							t.string('name')
							t.string('commit')
							t.string('buildId')
							t.string('image')
							t.json('environment')
							t.json('config')

				@knex.schema.hasTable('dependentDeviceTarget')
				.then (exists) =>
					if not exists
						@knex.schema.createTable 'dependentDeviceTarget', (t) ->
							t.increments('id').primary()
							t.string('uuid')
							t.string('name')
							t.json('apps')

				@knex.schema.hasTable('dependentApp')
				.then (exists) =>
					if not exists
						@knex.schema.createTable 'dependentApp', (t) ->
							t.increments('id').primary()
							t.string('appId')
							t.string('parentApp')
							t.string('name')
							t.string('commit')
							t.string('buildId')
							t.string('image')
							t.json('environment')
							t.json('config')

				@knex.schema.hasTable('dependentDevice')
				.then (exists) =>
					if not exists
						@knex.schema.createTable 'dependentDevice', (t) ->
							t.increments('id').primary()
							t.string('uuid')
							t.string('appId')
							t.string('localId')
							t.string('device_type')
							t.string('logs_channel')
							t.string('deviceId')
							t.boolean('is_online')
							t.string('name')
							t.string('status')
							t.string('download_progress')
							t.string('is_managed_by')
							t.dateTime('lock_expiry_date')
							t.string('commit')
							t.string('targetCommit')
							t.json('environment')
							t.json('targetEnvironment')
							t.json('config')
							t.json('targetConfig')
							t.boolean('markedForDeletion')
					else
						Promise.all [
							@addColumn('dependentDevice', 'markedForDeletion', 'boolean')
							@addColumn('dependentDevice', 'localId', 'string')
							@addColumn('dependentDevice', 'is_managed_by', 'string')
							@addColumn('dependentDevice', 'lock_expiry_date', 'dateTime')
					]

				@knex.schema.hasTable('image')
				.then (exists) =>
					if not exists
						@knex.schema.createTable 'image', (t) ->
							t.increments('id').primary()
							t.string('image')
			])
		.then ->
			return migrationNeeded

	# Returns a knex object for one of the models (tables)
	models: (modelName) =>
		@knex(modelName)

	upsertModel: (modelName, obj, id, trx) =>
		knex = trx ? @knex
		knex(modelName).update(obj).where(id)
		.then (n) ->
			knex(modelName).insert(obj) if n == 0

	transaction: (cb) =>
		@knex.transaction(cb)
