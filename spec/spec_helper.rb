require 'pry'
require 'active_record'
require 'active_pipeline'

ActiveRecord::Base.establish_connection(
  adapter: 'postgresql',
  host: ENV.fetch('DB_HOST', 'localhost'),
  database: 'active_pipeline_test',
  username: ENV.fetch('DB_USER', 'postgres'),
  password: ENV.fetch('DB_PASSWORD', 'postgres')
)

ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :name
    t.string :email
    t.timestamps
  end

  create_table :posts, force: true do |t|
    t.integer :user_id
    t.string :title
    t.timestamps
  end
  
  add_index :users, :email, unique: true
end

class User < ActiveRecord::Base
  has_many :posts
end

class Post < ActiveRecord::Base
  belongs_to :user
end

RSpec.configure do |config|
  config.before(:suite) do
    ActivePipeline.batch_window_ms = 10
    ActivePipeline.start!
  end
  
  config.after(:suite) do
    ActivePipeline.stop!
  end
  
  config.around(:each) do |example|
    User.delete_all
    Post.delete_all
    example.run
  end
end