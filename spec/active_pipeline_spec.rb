require 'spec_helper'

RSpec.describe ActivePipeline do
  it "batches inserts transparently" do
    user1 = Thread.new { User.create!(name: "Alice", email: "alice@example.com") }
    user2 = Thread.new { User.create!(name: "Bob", email: "bob@example.com") }
    
    user1.join
    user2.join
    
    expect(User.count).to eq(2)
    expect(User.pluck(:name)).to match_array(["Alice", "Bob"])
  end

  it "isolates errors and commits successful queries" do
    User.create!(name: "Existing", email: "duplicate@example.com")

    success = Thread.new { User.create!(name: "Valid", email: "valid@example.com") }
    failure = Thread.new do 
      begin
        User.create!(name: "Invalid", email: "duplicate@example.com")
      rescue ActiveRecord::StatementInvalid
        :failed
      end
    end

    success.join
    expect(failure.value).to eq(:failed)

    expect(User.count).to eq(2)
    expect(User.pluck(:name)).to match_array(["Existing", "Valid"])
  end

  it "batches operations per model in parallel" do
    t1 = Thread.new { User.create!(name: "User1", email: "u1@example.com") }
    t2 = Thread.new { Post.create!(title: "Post1") }
    
    t1.join
    t2.join
    
    expect(User.count).to eq(1)
    expect(Post.count).to eq(1)
  end
  
  it "handles updates" do
    user = User.create!(name: "Old Name", email: "update@example.com")
    
    t1 = Thread.new { user.update!(name: "New Name") }
    t1.join
    
    expect(user.reload.name).to eq("New Name")
  end
  
  it "handles deletes" do
    user = User.create!(name: "Delete Me", email: "delete@example.com")
    
    t1 = Thread.new { user.destroy! }
    t1.join
    
    expect(User.count).to eq(0)
  end
  
  it "allows bypassing the pipeline" do
    ActivePipeline.bypass do
      User.create!(name: "Bypass", email: "bypass@example.com")
    end
    expect(User.count).to eq(1)
  end
end