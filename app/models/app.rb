class App < ActiveRecord::Base
  has_many :emails
  has_many :deliveries
  belongs_to :team

  validates :name, presence: true, format: {with: /\A[a-zA-Z0-9_ ]+\z/, message: "Only letters, numbers, spaces and underscores"}
  validate :custom_tracking_domain_points_to_correct_place

  before_create :set_smtp_password
  after_create :set_smtp_username

  def self.cuttlefish
    App.find_by(cuttlefish: true) || App.create(cuttlefish: true, name: "Cuttlefish")
  end

  def new_password!
    unless smtp_password_locked?
      set_smtp_password
      save!
    end
  end

  def from_domain
    if cuttlefish?
      Rails.configuration.cuttlefish_domain
    else
      read_attribute(:from_domain)
    end
  end

  def dkim_key
    OpenSSL::PKey::RSA.new(dkim_private_key)
  end

  def dkim_public_key
    # We can generate the public key from the private key
    dkim_key.public_key.to_pem
  end

  # The string that needs to be inserted in DNS.
  # This string format works at least for the service DNS Made Easy.
  def dkim_public_key_dns_dnsmadeeasy
    App.quote_long_dns_txt_record("k=rsa; p=" + dkim_public_key.split("\n")[1..-2].join)
  end

  def dkim_public_key_dns_generic
    dkim_public_key_dns_cloudflare
  end

  def dkim_public_key_dns_cloudflare
    dkim_public_key_dns_dnsmadeeasy.gsub('"', '')
  end

  # This is the expected form of the correctly configured TXT entry when we are doing a DNS lookup
  def dkim_public_key_dns_lookup
    dkim_public_key_dns_dnsmadeeasy.gsub('"', '')
  end

  def dkim_dns_entry
    # Use our default nameserver
    begin
      Resolv::DNS.new.getresource("cuttlefish._domainkey.#{from_domain}", Resolv::DNS::Resource::IN::TXT).strings.join
    rescue Resolv::ResolvError
      nil
    end
  end

  def dkim_private_key
    update_attributes(dkim_private_key: OpenSSL::PKey::RSA.new(2048).to_pem) if read_attribute(:dkim_private_key).nil?
    read_attribute(:dkim_private_key)
  end

  def dkim_dns_configured?
    dkim_dns_entry == dkim_public_key_dns_lookup
  end

  def tracking_domain
    if custom_tracking_domain?
      custom_tracking_domain
    else
      Rails.configuration.cuttlefish_domain
    end
  end

  # Are we using a custom tracking domain?
  def custom_tracking_domain?
    custom_tracking_domain.present?
  end

  private

  # If a DNS TXT record is longer than 255 characters it needs to be split into several
  # separate strings
  def self.quote_long_dns_txt_record(text)
    text.scan(/.{1,255}/).map{|s| '"' + s + '"'}.join
  end

  def self.lookup_dns_cname_record(domain)
    # Use our default nameserver
    begin
      n = Resolv::DNS.new.getresource(domain, Resolv::DNS::Resource::IN::CNAME).name
      # Doing this to maintain compatibility with previous implementation
      # of this method
      if n.absolute?
        n.to_s + "."
      else
        n.to_s
      end
    rescue Resolv::ResolvError
      nil
    end
  end

  def custom_tracking_domain_points_to_correct_place
    # In DNS speak putting a "." after the domain makes it a full domain name rather than just relative
    # to the current higher level domain
    cname_domain = Rails.configuration.cuttlefish_domain + "."
    unless custom_tracking_domain.blank?
      if App.lookup_dns_cname_record(custom_tracking_domain) != cname_domain
        errors.add(:custom_tracking_domain, "Doesn't have a CNAME record that points to #{cname_domain}")
      end
    end
  end

  def set_smtp_password
    self.smtp_password = Digest::MD5.base64digest(rand.to_s + Time.now.to_s)[0...20]
  end

  def set_smtp_username
    # By appending the id we can be confident that this name is globally unique
    update_attributes(smtp_username: name.downcase.gsub(" ", "_") + "_" + id.to_s)
  end
end
