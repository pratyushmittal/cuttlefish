require 'spec_helper'
require File.expand_path File.join(File.dirname(__FILE__), '..', '..', 'lib', 'cuttlefish_smtp_server')
require 'sidekiq/testing'

describe CuttlefishSmtpConnection do
  let(:connection) { CuttlefishSmtpConnection.new('') }
  let(:app) { App.create!(name: "test") }

  describe "#receive_plain_auth" do
    it { expect(connection.receive_plain_auth("foo", "bar")).to eq false }
    it { expect(connection.receive_plain_auth(app.smtp_username, "bar")).to eq false }
    it { expect(connection.receive_plain_auth(app.smtp_username, app.smtp_password)).to eq true }
  end

  describe "#get_server_greeting" do
    it { expect(connection.get_server_greeting).to eq "Cuttlefish SMTP server waves its arms and tentacles and says hello" }
  end

  describe "#get_server_domain" do
    it do
      expect(Rails.configuration).to receive(:cuttlefish_domain).and_return("cuttlefish.io")
      expect(connection.get_server_domain).to eq "cuttlefish.io"
    end
  end

  describe "#receive_sender" do
    it do
      expect(connection.receive_sender("matthew@foo.com")).to eq true
      expect(connection.current.sender).to eq "matthew@foo.com"
    end
  end

  describe "#receive_recipient" do
    it do
      expect(connection.receive_recipient("matthew@foo.com")).to eq true
      expect(connection.receive_recipient("bar@camp.com")).to eq true
      expect(connection.current.recipients).to eq ["matthew@foo.com", "bar@camp.com"]
    end
  end

  describe "#receive_data_command" do
    it do
      connection.current.data = "some left over data that shouldn't be there"
      expect(connection.receive_data_command).to eq true
      expect(connection.current.data).to eq ""
    end
  end

  describe "#receive_data_chunk" do
    it do
      connection.current.data = "some data already received\n"
      expect(connection.receive_data_chunk(["foo", "bar"])).to eq true
      expect(connection.current.data).to eq "some data already received\nfoo\nbar"
    end
  end

  describe ".default_parameters" do
    it {expect(CuttlefishSmtpConnection.default_parameters[:auth]).to eq :required}
    it {expect(CuttlefishSmtpConnection.default_parameters[:starttls]).to eq :required}
    it do
      expect(Rails.configuration).to receive(:cuttlefish_domain_cert_chain_file).and_return("/foo/bar")
      expect(Rails.configuration).to receive(:cuttlefish_domain_private_key_file).and_return("/foo/private")
      expect(CuttlefishSmtpConnection.default_parameters[:starttls_options]).to eq ({
        cert_chain_file: "/foo/bar",
        private_key_file: "/foo/private"
      })
    end
  end
  describe "#receive_message" do
    it do
      allow_any_instance_of(OutgoingDelivery).to receive(:send)
      data = [
          "MIME-Version: 1.0",
          "Content-Type: text/plain; charset=\"utf-8\"",
          "Content-Transfer-Encoding: 8bit",
          "Subject: [WriteIT] Message: asdasd",
          "From: Felipe <felipe@fiera-feroz.cl>, Matthew <matthew@fiera-feroz.cl>",
          "To: felipe@fiera-feroz.cl",
          "Date: Fri, 13 Mar 2015 14:42:20 -0000",
          "Message-ID: <20150313144220.12848.46019@paro-taktsang>",
          "",
          "Contra toda autoridad!...excepto mi mamá!"].join("\n")
      # Simulate the encoding that we would assume when the data is received
      # over the wire so to speak
      data.force_encoding("ASCII-8BIT")
      connection.receive_sender("ciudadanoi@email.org")
      connection.receive_recipient('Felipe <felipe@fiera-feroz.cl>')
      connection.receive_recipient('Matthew <matthew@fiera-feroz.cl>')
      connection.receive_plain_auth(app.smtp_username, app.smtp_password)
      connection.current.data = data
      Sidekiq::Testing.inline! do
        connection.receive_message
      end
      expect(Email.count).to eq 1
      mail = Email.first
      expect(Mail.new(mail.data).decoded).to eq("Contra toda autoridad!...excepto mi mamá!")
    end
  end
end
