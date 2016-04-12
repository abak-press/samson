require_relative '../test_helper'

# kitchen sink for 1-off tests
describe "cleanliness" do
  it "does not have boolean limit 1 in schema since this breaks mysql" do
    File.read("db/schema.rb").wont_match /\st\.boolean.*limit: 1/
  end

  it "does not include rails-assets-bootstrap" do
    # make sure rails-assets-bootstrap did not get included by accident (dependency of some other bootstrap thing)
    # if it is not avoidable see http://stackoverflow.com/questions/7163264
    File.read('Gemfile.lock').wont_include 'rails-assets-bootstrap '
  end

  if ENV['USE_UTF8MB4'] && ActiveRecord::Base.connection.adapter_name == "Mysql2"
    it "uses the right row format in mysql" do
      status = ActiveRecord::Base.connection.execute('show table status').to_a
      refute_empty status
      status.each do |table|
        table[3].must_equal "Dynamic"
      end
    end
  end

  it "does not use let(:user) inside of a as_xyz block" do
    bad = Dir["{,plugins/*/}test/controllers/**/*.rb"].map do |f|
      content = File.read(f)
      if content.include?("  as_") && content.include?("let(:user)")
        "#{f} uses as_xyz and let(:user) these do not mix!"
      end
    end.compact
    bad.must_equal []
  end

  it "does not have actions on base controller" do
    found = ApplicationController.action_methods.to_a
    found.reject { |a| a =~ /^(_conditional_callback_around_|_callback_before_)/ } - ["flash"]
    found.must_equal []
  end
end
