# frozen_string_literal: true

RSpec.describe ActivePipeline::Payload do
  def build(sql = 'INSERT INTO "users" ("name") VALUES ($1)')
    described_class.new(operation: :insert, sql: sql, binds: ["x"], db_config: :db)
  end

  describe ".table_name_for" do
    {
      'INSERT INTO "users" ("name") VALUES ($1)' => "users",
      'UPDATE "users" SET "name" = $1 WHERE "users"."id" = $2' => "users",
      'DELETE FROM "users" WHERE "users"."id" = $1' => "users",
      "insert into posts (title) values ('x')" => "posts",
      'INSERT INTO "public"."users" ("name") VALUES ($1)' => "public.users",
      'INSERT INTO "odd ""quoted"" table" DEFAULT VALUES' => 'odd quoted table',
      "/*application:Sidekiq*/ UPDATE users SET name = 'x'" => "users"
    }.each do |sql, table|
      it "extracts #{table.inspect} from #{sql[0, 40].inspect}" do
        expect(described_class.table_name_for(sql)).to eq(table)
      end
    end

    it "returns nil for statements it does not understand" do
      expect(described_class.table_name_for('WITH t AS (SELECT 1) UPDATE "users" SET name = 1')).to be_nil
    end
  end

  it "groups unknown statements together" do
    payload = build("WITH x AS (SELECT 1) DELETE FROM users")

    expect(payload.table_name).to eq(described_class::UNKNOWN_TABLE)
    expect(payload.group_key).to eq([:db, "unknown"])
  end

  describe "#wait" do
    it "returns the fulfilled value" do
      payload = build
      payload.fulfill(42)

      expect(payload.wait).to eq(42)
      expect(payload).to be_resolved
    end

    it "raises the rejection reason" do
      payload = build
      payload.reject(ArgumentError.new("bad"))

      expect { payload.wait }.to raise_error(ArgumentError, "bad")
    end

    it "raises TimeoutError when nothing resolves it in time" do
      expect { build.wait(0.01) }.to raise_error(ActivePipeline::TimeoutError)
    end

    it "keeps the first resolution" do
      payload = build
      payload.fulfill(1)
      payload.fulfill(2)
      payload.reject(RuntimeError.new)

      expect(payload.wait).to eq(1)
    end
  end
end
