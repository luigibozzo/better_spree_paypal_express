require 'rspec'
require 'spec_helper'
require 'models/fake_pay_pay_provider'

describe Spree::PaypalController do

  before do
    @order = Spree::Order.new
    @controller.stub(:current_order).and_return(@order)
  end

  describe 'When we call PayPal Express Checkout' do

    @fake_pay_pal_provider

    before(:each) do
      Spree::Country.stub(:find_by_iso).and_return( Spree::Country.new)

      payment_method = Spree::Gateway::PayPalExpress.new
      @controller.stub(:payment_method).and_return(payment_method)

      @fake_pay_pal_provider = FakePayPalProvider.new
      payment_method.stub(:provider).and_return(@fake_pay_pal_provider)

      @controller.stub(:redirect_to)
      @fake_pay_pal_provider.stub(:set_express_checkout).and_return(Hashie::Mash.new({:success? => true}))
      @fake_pay_pal_provider.stub(:express_checkout_url)
    end

    describe "and we have not come from the payments page" do

      before do
        @order.state = "not payment"
      end

      it 'should have parameters for Callback' do
        @fake_pay_pal_provider.should_receive(:build_set_express_checkout).with({:SetExpressCheckoutRequestDetails => hash_including(:CallbackURL)})

        @controller.express
      end

    end

    describe "and we have come from the payments page" do

      before do
        @order.state = "payment"
      end

      it 'should not have parameters for Callback' do
        @fake_pay_pal_provider.should_receive(:build_set_express_checkout).with({:SetExpressCheckoutRequestDetails => hash_excluding(:CallbackURL)})

        @controller.express
      end

    end

  end

  describe 'When PayPal calls the confirm action' do

    before(:each) do
      Spree::Country.stub(:find_by_iso).and_return( Spree::Country.new)

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
                                                      :ContactPhone => '1234567',
                                                      :UserSelectedOptions => {
                                                          :ShippingOptionName => "Shipping Option 2",
                                                          :ShippingCalculationMode => "Callback"
                                                      }
                                                     })

      fake_pay_pal_provider = FakePayPalProvider.new
      fake_pay_pal_provider.set_checkout_response(checkout_details_response)
      payment_method.stub(:provider).and_return(fake_pay_pal_provider)
    end

    it 'should update order with shipping address information' do
      @controller.stub(:set_shipping_rate)

      spree_get :confirm

      expect(@order.email).to eq("a@b.com")
      @order.ship_address.should_not be_nil
      expect(@order.ship_address.firstname).to eq("John")
      expect(@order.ship_address.lastname).to eq("Smith")
      expect(@order.ship_address.address1).to eq("A House")
      expect(@order.ship_address.address2).to eq("A Street")
      expect(@order.ship_address.city).to eq("A City")
      expect(@order.ship_address.phone).to eq("1234567")
      expect(@order.ship_address.zipcode).to eq("TR4 0TH")
    end

    it 'should update order with shipping option' do

      shipping_options = [Hashie::Mash.new({:id => 1, :shipping_method => {:name => "Shipping Option 1"}}),
                          Hashie::Mash.new({:id => 2, :shipping_method => {:name => "Shipping Option 2"}})]
      @controller.stub(:get_shipping_rates).and_return(shipping_options)

      shipment = mock_model(Spree::Shipment)
      shipment.should_receive(:selected_shipping_rate_id=).with(2)
      @order.stub(:shipment).and_return(shipment)

      spree_get :confirm
    end

    describe 'and the shipping method is Fallback' do

      before(:each) do
        Spree::Country.stub(:find_by_iso).and_return( Spree::Country.new)

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
                                                       :ContactPhone => '1234567',
                                                       :UserSelectedOptions => {
                                                           :ShippingOptionName => "Shipping Option 2",
                                                           :ShippingCalculationMode => "Fallback"
                                                       }
                                                      })

        fake_pay_pal_provider = FakePayPalProvider.new
        fake_pay_pal_provider.set_checkout_response(checkout_details_response)
        payment_method.stub(:provider).and_return(fake_pay_pal_provider)
      end

      it 'should cancel the transaction' do
        spree_get :confirm

        response.should redirect_to :action => :cancel, :error => "There was a problem with PayPal. You have not been charged. Please try again"
      end

    end

  end

  describe 'When cancelling PayPal express payment' do
    it 'should redirect to cart page when cancelling from super express checkout' do
      @order.state = 'cart'
      spree_get :cancel
      response.should redirect_to spree.cart_path
    end
  end

  it 'should redirect to checkout path when not in super express checkout' do
    @order.state = 'payment'
    spree_get :cancel
    response.should redirect_to spree.checkout_state_path(@order.state)
  end

  describe 'Callback response to Paypal' do

    it 'should respond with no shipping option details when country is not present' do
      Spree::Country.stub(:find_by_iso).and_return(nil)
      request_from_paypal = {"SHIPTOCOUNTRY" => "blah"}

      spree_post :callback, request_from_paypal
      expect(response.body).to eq('&METHOD=CallbackResponse&NO_SHIPPING_OPTION_DETAILS=1')
    end

    it 'should respond with no shipping option when there are no shipping methods for that product in that country' do
      Spree::Country.stub(:find_by_iso).and_return(Spree::Country.new)
      request_from_paypal = {"SHIPTOCOUNTRY" => "GB"}
      @order.stub(:create_proposed_shipments).and_return([])
      @order.stub(:shipments).and_return([])
      spree_post :callback, request_from_paypal
      expect(response.body).to eq('&METHOD=CallbackResponse&NO_SHIPPING_OPTION_DETAILS=1')
    end

    it 'should respond with the proper shipping options for express checkout given request from Paypal' do
      Spree::Country.stub(:find_by_iso).and_return( Spree::Country.new)
      request_from_paypal = {"SHIPTOCOUNTRY" => "GB", "CURRENCYCODE" => "GBP"}
      shipment = Spree::Shipment.new
      shipping_rate_1 = Spree::ShippingRate.new shipping_method: (Spree::ShippingMethod.new name:'Rocket'), cost: 500
      shipping_rate_2 = Spree::ShippingRate.new shipping_method: (Spree::ShippingMethod.new name:'Drone'), cost: 3

      shipment.shipping_rates = [shipping_rate_1, shipping_rate_2]


      @order.stub(:create_proposed_shipments).and_return([shipment])
      @order.stub(:shipments).and_return([shipment])

      spree_post :callback, request_from_paypal

      callbackResponse =  '&METHOD=CallbackResponse'\
                          '&CURRENCYCODE=GBP'\
                          '&L_SHIPPINGOPTIONNAME0='\
                          '&L_SHIPPINGOPTIONLABEL0=Rocket'\
                          '&L_SHIPPINGOPTIONAMOUNT0=500.0'\
                          '&L_SHIPPINGOPTIONISDEFAULT0=true'\
                          '&L_SHIPPINGOPTIONNAME1='\
                          '&L_SHIPPINGOPTIONLABEL1=Drone'\
                          '&L_SHIPPINGOPTIONAMOUNT1=3.0'\
                          '&L_SHIPPINGOPTIONISDEFAULT1=false'

      expect(response.body).to eq(callbackResponse)

    end

  end

end