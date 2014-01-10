require 'rspec'
require 'spec_helper'
require 'models/fake_pay_pay_provider'

describe Spree::PaypalController do

  describe 'updating order with information from paypal' do

    it 'should update order with shipping address information' do
      #pending("Can't get spree_get to work...")
      Spree::Country.stub(:find_by_iso).and_return( Spree::Country.new)

      order = Spree::Order.new
      @controller.stub(:current_order).and_return(order)
      payment_method = Spree::Gateway::PayPalExpress.new
      @controller.stub(:payment_method).and_return(payment_method)

      checkout_details_response =  Hashie::Mash.new({:PaymentDetails => [{
          :ShipToAddress => {
              :Name => 'John Smith',
              :Street1 => 'A House',
              :Street2 => 'A Street',
              :CityName => 'A City',
              :country => 'GB',
              :PostalCode => 'TR4 0TH'
          }}],
          :PayerInfo => {
            :Payer => "a@b.com"
          },
          :ContactPhone => '1234567'
                                                    })

      fake_pay_pal_provider = FakePayPalProvider.new
      fake_pay_pal_provider.set_checkout_response(checkout_details_response)
      payment_method.stub(:provider).and_return(fake_pay_pal_provider)
      spree_get :confirm

      expect(order.email).to eq("a@b.com")
      order.ship_address.should_not be_nil
      expect(order.ship_address.firstname).to eq("John")
      expect(order.ship_address.lastname).to eq("Smith")
      expect(order.ship_address.address1).to eq("A House")
      expect(order.ship_address.address2).to eq("A Street")
      expect(order.ship_address.city).to eq("A City")
      expect(order.ship_address.phone).to eq("1234567")
      expect(order.ship_address.zipcode).to eq("TR4 0TH")
    end
  end
end