# frozen_string_literal: true

RSpec.describe ActivePipeline do
  it "has a version number" do
    expect(ActivePipeline::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  describe ".configure" do
    it "yields the module for settings" do
      described_class.configure do |config|
        config.batch_window_ms = 5
        config.max_batch_size = 10
      end

      expect(described_class.batch_window_ms).to eq(5)
      expect(described_class.max_batch_size).to eq(10)
    end
  end

  describe ".start! / .stop!" do
    it "is idempotent" do
      first = worker
      described_class.start!

      expect(worker).to be(first)
      expect(described_class).to be_running
    end

    it "stops and starts a fresh worker" do
      old = worker
      described_class.stop!
      expect(described_class).not_to be_running

      described_class.start!
      expect(described_class).to be_running
      expect(worker).not_to be(old)
    end

    it "lets queued statements finish before stopping" do
      described_class.batch_window_ms = 500

      writers = Array.new(5) { |i| Thread.new { User.create!(name: "drain-#{i}") } }
      sleep 0.2 # writers are now parked inside the worker's 500ms window
      described_class.stop!

      expect(writers.map(&:value)).to all(be_persisted)
      expect(User.count).to eq(5)
    end
  end

  describe ".bypass" do
    it "routes writes straight through ActiveRecord" do
      events = capture_batches do
        described_class.bypass { User.create!(name: "direct") }
      end

      expect(events).to be_empty
      expect(User.pluck(:name)).to eq(["direct"])
    end

    it "restores the outer state when nested" do
      described_class.bypass do
        described_class.bypass { nil }
        expect(described_class).to be_bypassed
      end

      expect(described_class).not_to be_bypassed
    end

    it "restores the state when the block raises" do
      expect { described_class.bypass { raise "boom" } }.to raise_error("boom")
      expect(described_class).not_to be_bypassed
    end
  end

  describe "fallback to regular writes" do
    it "does not pipeline when disabled" do
      described_class.enabled = false

      events = capture_batches { User.create!(name: "disabled") }

      expect(events).to be_empty
      expect(User.count).to eq(1)
    end

    it "does not block writes when the worker is not running" do
      described_class.stop!

      events = capture_batches do
        user = User.create!(name: "no worker")
        user.update!(name: "still no worker")
        user.destroy!
      end

      expect(events).to be_empty
      expect(User.count).to eq(0)
    end

    it "does not route to an inherited worker after a fork" do
      allow(Process).to receive(:pid).and_return(Process.pid + 1)

      expect(described_class).not_to be_running
      expect(described_class.enqueue(double)).to be(false)
      expect(User.create!(name: "child process")).to be_persisted
    end

    it "abandons an inherited worker on stop! without touching its connections" do
      User.create!(name: "warm up")
      inherited = worker
      adapters = inherited.instance_variable_get(:@adapters).values
      allow(Process).to receive(:pid).and_return(Process.pid + 1)

      described_class.stop!

      expect(described_class).not_to be_running
      expect(adapters).to all(be_active)
    ensure
      allow(Process).to receive(:pid).and_call_original
      inherited.stop! # in a real fork this worker lives on in the parent process
    end

    it "releases waiting callers and falls back when the worker thread dies" do
      current = worker
      current.instance_variable_get(:@thread).report_on_exception = false
      allow(current).to receive(:process_batch).and_raise(RuntimeError, "worker crashed")

      expect { User.create!(name: "lost") }.to raise_error(RuntimeError, "worker crashed")
      sleep 0.01 while current.running?

      expect(User.create!(name: "after crash")).to be_persisted
      expect(User.pluck(:name)).to eq(["after crash"])
      expect { current.stop! }.not_to raise_error
    end
  end
end
