# frozen_string_literal: true

RSpec.describe "Pipelined writes" do
  describe "routing" do
    it "sends INSERT, UPDATE and DELETE through the worker" do
      events = capture_batches do
        user = User.create!(name: "Alice")
        user.update!(name: "Alicia")
        user.destroy!
      end

      expect(events.map { |e| e[:table] }).to eq(%w[users users users])
      expect(User.count).to eq(0)
    end

    it "keeps reads on the regular connection" do
      User.create!(name: "Alice")

      events = capture_batches { User.where(name: "Alice").to_a }

      expect(events).to be_empty
    end

    it "instruments pipelined statements as sql.active_record" do
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql]
      end
      User.create!(name: "Logged")

      expect(queries).to include(a_string_matching(/\AINSERT INTO "users" .* RETURNING "id"\z/))
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  describe "return values" do
    it "returns the generated primary key for inserts" do
      user = User.create!(name: "Alice")

      expect(user.id).to be_a(Integer)
      expect(User.find(user.id).name).to eq("Alice")
    end

    it "returns custom RETURNING columns" do
      result = User.insert({ name: "Returning" }, returning: %w[id name])

      expect(result.rows.first.last).to eq("Returning")
    end

    it "returns the number of affected rows for update_all and delete_all" do
      3.times { |i| User.create!(name: "user-#{i}") }

      expect(User.where("name LIKE 'user-%'").update_all(active: false)).to eq(3)
      expect(User.where(active: false).delete_all).to eq(3)
      expect(User.where(name: "missing").delete_all).to eq(0)
    end

    it "round-trips typed binds" do
      seen_at = Time.utc(2026, 1, 2, 3, 4, 5)
      avatar = "\x00\xFFbinary".b

      user = User.create!(name: "Typed", active: false, settings: { "a" => [1, 2] }, avatar: avatar, seen_at: seen_at)
      user.reload

      expect(user.active).to be(false)
      expect(user.settings).to eq("a" => [1, 2])
      expect(user.avatar).to eq(avatar)
      expect(user.seen_at).to eq(seen_at)
      expect(user.created_at).to be_within(5).of(Time.now)
    end
  end

  describe "batching" do
    before { ActivePipeline.batch_window_ms = 200 }

    it "flushes concurrent writes as a single pipeline" do
      events = capture_batches do
        users = concurrently(10) { |i| User.create!(name: "user-#{i}") }
        expect(users).to all(be_persisted)
      end

      expect(events.size).to eq(1)
      expect(events.first).to include(table: "users", size: 10, rounds: 1, failed: 0)
      expect(User.count).to eq(10)
    end

    it "groups statements per table" do
      events = capture_batches do
        concurrently(6) { |i| i.even? ? User.create!(name: "user-#{i}") : Post.create!(title: "post-#{i}") }
      end

      expect(events.map { |e| [e[:table], e[:size]] }).to contain_exactly(["users", 3], ["posts", 3])
    end

    it "splits batches at max_batch_size" do
      ActivePipeline.max_batch_size = 4

      events = capture_batches { concurrently(10) { |i| User.create!(name: "user-#{i}") } }

      expect(events.map { |e| e[:size] }).to all(be <= 4)
      expect(events.sum { |e| e[:size] }).to eq(10)
      expect(User.count).to eq(10)
    end

    it "does not lose writes under load" do
      ActivePipeline.batch_window_ms = 10

      events = capture_batches do
        concurrently(20) { |t| 10.times { |i| User.create!(name: "t#{t}-#{i}") } }
      end

      expect(User.count).to eq(200)
      expect(User.distinct.count(:name)).to eq(200)
      expect(events.size).to be < 200
    end
  end

  describe "error isolation" do
    before { ActivePipeline.batch_window_ms = 200 }

    it "rejects only the failing statement and commits the rest" do
      User.create!(name: "Existing", email: "taken@example.com")

      results = nil
      events = capture_batches do
        results = concurrently(5) do |i|
          User.create!(name: "user-#{i}", email: i == 2 ? "taken@example.com" : "user-#{i}@example.com")
        end
      end

      errors = results.grep(Exception)
      expect(errors.size).to eq(1)
      expect(errors.first).to be_a(ActiveRecord::RecordNotUnique)
      expect(errors.first.sql).to start_with('INSERT INTO "users"')
      expect(User.where.not(name: "Existing").pluck(:name)).to contain_exactly("user-0", "user-1", "user-3", "user-4")
      expect(events.last).to include(size: 5, rounds: 2, failed: 1)
    end

    it "isolates several failures in the same batch" do
      User.create!(name: "Existing", email: "taken@example.com")

      results = concurrently(6) do |i|
        User.create!(name: "user-#{i}", email: i.odd? ? "taken@example.com" : "user-#{i}@example.com")
      end

      expect(results.grep(ActiveRecord::RecordNotUnique).size).to eq(3)
      expect(User.count).to eq(4)
    end

    it "translates database errors into ActiveRecord exceptions" do
      User.create!(name: "Alice")

      expect { User.create!(name: nil) }.to raise_error(ActiveRecord::NotNullViolation)
      expect { User.update_all("active = (1 / 0 = 1)") }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "rejects the whole group when the implicit commit fails" do
      results = concurrently(2) do |i|
        Post.create!(title: "post-#{i}", user_id: i.zero? ? nil : 999_999)
      end

      expect(results).to all(be_a(ActiveRecord::InvalidForeignKey))
      expect(Post.count).to eq(0)
    end

    it "keeps working after a statement fails" do
      expect { User.create!(name: nil) }.to raise_error(ActiveRecord::NotNullViolation)
      expect(User.create!(name: "after failure")).to be_persisted
    end
  end

  describe "transactions" do
    it "runs statements of a materialized transaction on the caller's connection" do
      user = User.create!(name: "Locked")

      events = capture_batches do
        User.transaction do
          User.lock.find(user.id) # row lock held by this connection
          user.update!(name: "Updated under lock")
        end
      end

      expect(events).to be_empty
      expect(user.reload.name).to eq("Updated under lock")
    end

    it "honours rollbacks once the transaction is materialized" do
      User.transaction do
        User.count
        User.create!(name: "rolled back")
        raise ActiveRecord::Rollback
      end

      expect(User.count).to eq(0)
    end

    it "commits writes of a lazy transaction independently (documented tradeoff)" do
      User.transaction do
        User.create!(name: "escaped")
        raise ActiveRecord::Rollback
      end

      expect(User.pluck(:name)).to eq(["escaped"])
    end
  end

  describe "resilience" do
    it "raises TimeoutError when the statement is not resolved within wait_timeout" do
      user = User.create!(name: "Contended")
      ActivePipeline.wait_timeout = 0.3
      locked = Concurrent::Event.new
      release = Concurrent::Event.new

      holder = Thread.new do
        User.transaction do
          User.lock.find(user.id)
          locked.set
          release.wait(5)
        end
      end
      locked.wait(5)

      expect { User.where(id: user.id).update_all(name: "late") }.to raise_error(ActivePipeline::TimeoutError)

      release.set
      holder.join
      # The statement was not cancelled: it commits once the lock is released.
      sleep 0.1 until User.find(user.id).name == "late"
    end

    it "recovers when the worker's connection is killed" do
      User.create!(name: "warm up")
      pids = worker_backend_pids
      ActiveRecord::Base.connection.execute("SELECT pg_terminate_backend(pid) FROM unnest(ARRAY#{pids}) AS pid")

      begin
        User.create!(name: "maybe")
      rescue ActiveRecord::ActiveRecordError => e
        expect(e).to be_a(ActiveRecord::ConnectionFailed).or be_a(ActiveRecord::StatementInvalid)
      end

      expect(User.create!(name: "recovered")).to be_persisted
      expect(worker_backend_pids).not_to eq(pids)
      expect(ActivePipeline).to be_running
    ensure
      # Other tables' worker connections were killed too; start from fresh ones.
      ActivePipeline.stop!
      ActivePipeline.start!
    end
  end
end
