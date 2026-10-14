# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  add_filter "/spec/"
  minimum_coverage line: 90, branch: 70

  if ENV["CI"]
    require "simplecov-lcov"
    SimpleCov::Formatter::LcovFormatter.config do |c|
      c.report_with_single_file = true
      c.single_report_path = "coverage/lcov.info"
    end
    formatter SimpleCov::Formatter::MultiFormatter.new(
      [SimpleCov::Formatter::HTMLFormatter, SimpleCov::Formatter::LcovFormatter]
    )
  end
end

require "active_pipeline"

DB_CONFIG = {
  adapter: "postgresql",
  host: ENV.fetch("DB_HOST", "localhost"),
  port: ENV.fetch("DB_PORT", 5432),
  database: ENV.fetch("DB_NAME", "active_pipeline_test"),
  username: ENV.fetch("DB_USER", "postgres"),
  password: ENV.fetch("DB_PASSWORD", "postgres"),
  pool: 50
}.freeze

ActiveRecord::Base.establish_connection(DB_CONFIG)
ActiveRecord::Migration.verbose = false

# A server-side timezone different from the UTC session ActiveRecord sets up,
# so specs catch worker connections that are not configured like the app's.
ActiveRecord::Base.connection.execute(
  "ALTER DATABASE #{ActiveRecord::Base.connection.quote_table_name(DB_CONFIG[:database])} SET timezone TO 'Asia/Tokyo'"
)
ActiveRecord::Base.connection_pool.disconnect!

ActiveRecord::Schema.define do
  create_table :users, force: :cascade do |t|
    t.string :name, null: false
    t.string :email
    t.boolean :active, default: true
    t.jsonb :settings, default: {}
    t.binary :avatar
    t.timestamptz :seen_at
    t.timestamps
  end
  add_index :users, :email, unique: true

  create_table :posts, force: :cascade do |t|
    t.integer :user_id
    t.string :title
    t.timestamps
  end

  execute <<~SQL
    ALTER TABLE posts
      ADD CONSTRAINT posts_user_fk FOREIGN KEY (user_id) REFERENCES users (id)
      DEFERRABLE INITIALLY DEFERRED
  SQL
end

class User < ActiveRecord::Base
  has_many :posts
end

class Post < ActiveRecord::Base
  belongs_to :user, optional: true
end

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.example_status_persistence_file_path = ".rspec_status"
  config.order = :random
  Kernel.srand config.seed

  config.include PipelineHelpers

  config.before(:suite) { ActivePipeline.start! }
  config.after(:suite) { ActivePipeline.stop! }

  config.around do |example|
    settings = %i[enabled batch_window_ms max_batch_size wait_timeout].to_h { |k| [k, ActivePipeline.public_send(k)] }
    ActivePipeline.configure do |c|
      c.batch_window_ms = 20
      # Fail fast instead of hanging the suite if a regression leaves a caller waiting.
      c.wait_timeout = 10
    end
    ActiveRecord::Base.connection.execute("TRUNCATE users, posts RESTART IDENTITY CASCADE")

    example.run
  ensure
    settings.each { |k, v| ActivePipeline.public_send(:"#{k}=", v) }
    ActivePipeline.start! unless ActivePipeline.running?
  end
end
