require_relative './spec_helper'

describe "PG::EM::Client::Helper#db_transaction" do
	let(:mock_conn) { double(PG::EM::Client) }

	it "runs a BEGIN/COMMIT cycle by default" do
		in_em do
			expect_query("BEGIN")
			expect_query("COMMIT")
			in_transaction do |txn|
				txn.commit
			end
		end
	end

	it "rolls back if BEGIN fails" do
		in_em do
			expect_query_failure("BEGIN")
			expect_query("ROLLBACK")
			in_transaction do |txn|
				txn.commit
			end
		end
	end

	it "doesn't roll back if COMMIT fails" do
		in_em do
			expect_query("BEGIN")
			expect_query_failure("COMMIT")
			in_transaction do |txn|
				txn.commit
			end
		end
	end

	it "fails the transaction if COMMIT fails" do
		dbl = double
		expect(dbl).to receive(:errback)
		expect(dbl).to_not receive(:callback)

		in_em do
			expect_query("BEGIN")
			expect_query_failure("COMMIT")
			in_transaction do |txn|
				txn.commit
			end.callback { dbl.callback }.errback { dbl.errback }
		end
	end

	it "runs a simple INSERT correctly" do
		in_em do
			expect_query("BEGIN")
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ["baz"])
			expect_query("COMMIT")
			in_transaction do |txn|
				txn.insert("foo", :bar => 'baz') do
					txn.commit
				end
			end
		end
	end

	it "rolls back after a failed INSERT" do
		in_em do
			expect_query("BEGIN")
			expect_query_failure('INSERT INTO "foo" ("bar") VALUES ($1)', ["baz"])
			expect_query("ROLLBACK")
			in_transaction do |txn|
				txn.insert("foo", :bar => 'baz') do
					txn.commit
				end
			end
		end
	end

	it "runs nested inserts in the right order" do
		in_em do
			expect_query("BEGIN")
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ['baz'])
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ['wombat'])
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ['quux'])
			expect_query("COMMIT")

			in_transaction do |txn|
				txn.insert("foo", :bar => 'baz') do
					txn.insert("foo", :bar => 'wombat') do
						txn.insert("foo", :bar => 'quux') do
							txn.commit
						end
					end
				end
			end
		end
	end

	it "is robust against slow queries" do
		# All tests up to now *could* have just passed "by accident", because
		# the queries were running fast enough to come out in order, even if
		# we weren't properly synchronising.  However, by making the second
		# insert run slowly, we should be able to be confident that we're
		# properly running the queries in order.
		in_em do
			expect_query("BEGIN")
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ['baz'])
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ['wombat'], 0.1)
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ['quux'])
			expect_query("COMMIT")

			in_transaction do |txn|
				txn.insert("foo", :bar => 'baz') do
					txn.insert("foo", :bar => 'wombat') do
						txn.insert("foo", :bar => 'quux') do
							txn.commit
						end
					end
				end
			end
		end
	end

	it "is robust against having an unrelated deferrable in the chain" do
		in_em do
			expect_query("BEGIN")
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ['baz'])
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ['wombat'])
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ['quux'])
			expect_query("COMMIT")

			in_transaction do |txn|
				txn.insert("foo", :bar => 'baz') do
					txn.insert("foo", :bar => 'wombat') do
						df = ::EM::DefaultDeferrable.new
						df.callback do
							txn.insert("foo", :bar => 'quux') do
								txn.commit
							end
						end
						df.succeed
					end
				end
			end
		end
	end

	it "doesn't COMMIT if we rolled back" do
		in_em do
			expect_query("BEGIN")
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ["baz"])
			expect_query("ROLLBACK")
			in_transaction do |txn|
				txn.insert("foo", :bar => 'baz') do
					txn.rollback("Because I can")
				end
			end
		end
	end

	it "catches exceptions" do
		in_em do
			expect_query("BEGIN")
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ["baz"])
			expect_query("ROLLBACK")
			in_transaction do |txn|
				txn.insert("foo", :bar => 'baz')
				raise "OMFG"
			end
		end
	end

	it "uses SERIALIZABLE if we ask nicely" do
		in_em do
			expect_query("BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE")
			expect_query("COMMIT")

			in_transaction(:isolation => :serializable) do |txn|
				txn.commit
			end
		end
	end

	it "uses REPEATABLE READ if we ask nicely" do
		in_em do
			expect_query("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ")
			expect_query("COMMIT")

			in_transaction(:isolation => :repeatable_read) do |txn|
				txn.commit
			end
		end
	end

	it "uses DEFERRABLE if we ask nicely" do
		in_em do
			expect_query("BEGIN DEFERRABLE")
			expect_query("COMMIT")

			in_transaction(:deferrable => true) do |txn|
				txn.commit
			end
		end
	end

	it "retries if it gets an error during the transaction" do
		in_em do
			expect_query("BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE")
			expect_query_failure('INSERT INTO "foo" ("bar") VALUES ($1)', ["baz"], PG::TRSerializationFailure.new("OMFG!"))
			expect_query("ROLLBACK")
			expect_query("BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE")
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ["baz"])
			expect_query("COMMIT")

			in_transaction(:isolation => :serializable, :retry => true) do |txn|
				txn.insert("foo", :bar => 'baz') do
					txn.commit
				end
			end
		end
	end

	it "retries if it gets an error on commit" do
		in_em do
			expect_query("BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE")
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ["baz"])
			expect_query_failure("COMMIT", [], PG::TRSerializationFailure.new("OMFG!"))
			expect_query("BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE")
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ["baz"])
			expect_query("COMMIT")

			in_transaction(:isolation => :serializable, :retry => true) do |txn|
				txn.insert("foo", :bar => 'baz') do
					txn.commit
				end
			end
		end
	end

	it "doesn't rollback back after a failed INSERT with autorollback = false" do
		in_em do
			expect_query("BEGIN")
			expect_query_failure('INSERT INTO "foo" ("bar") VALUES ($1)', ["baz"])
			expect_query('INSERT INTO "foo" ("bar") VALUES ($1)', ["wombat"])
			expect_query("COMMIT")
			in_transaction do |txn|
				txn.autorollback_on_error = false
				txn.insert("foo", :bar => 'baz').errback do
					txn.insert("foo", :bar => 'wombat') do
						txn.commit
					end
				end
			end
		end
	end
end
