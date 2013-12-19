require 'rspec'
require 'spec_helper'

describe Spree::PaypalController do

  describe 'updating order with information from paypal' do

    it 'should update order with shipping address information' do
      pending("Can't get spree_get to work...")
      order = Spree::Order.create
      @controller.stub(:current_order).and_return(order)

      spree_get :confirm

      order.ship_address.should_not be_nil
    end
  end
end