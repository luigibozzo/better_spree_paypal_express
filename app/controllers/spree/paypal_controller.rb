module Spree
  class PaypalController < StoreController
    def express
      fromPaymentPage = current_order.state == "payment"
      items = current_order.line_items.map do |item|
        {
            :Name => item.product.name,
            :Number => item.variant.sku,
            :Quantity => item.quantity,
            :Amount => {
                :currencyID => current_order.currency,
                :value => item.price
            },
            :ItemCategory => "Physical"
        }
      end

      tax_adjustments = current_order.adjustments.tax
      shipping_adjustments = current_order.adjustments.shipping

      current_order.adjustments.eligible.each do |adjustment|
        next if (tax_adjustments + shipping_adjustments).include?(adjustment)
        items << {
            :Name => adjustment.label,
            :Quantity => 1,
            :Amount => {
                :currencyID => current_order.currency,
                :value => adjustment.amount
            }
        }
      end

      # Because PayPal doesn't accept $0 items at all.
      # See #10
      # https://cms.paypal.com/uk/cgi-bin/?cmd=_render-content&content_ID=developer/e_howto_api_ECCustomizing
      # "It can be a positive or negative value but not zero."
      items.reject! do |item|
        item[:Amount][:value].zero?
      end

      paypal_parameters = {
              :ReturnURL => confirm_paypal_url(:payment_method_id => params[:payment_method_id], :utm_nooverride => 1),
              :CancelURL => cancel_paypal_url,
              :SolutionType => payment_method.preferred_solution.present? ? payment_method.preferred_solution : "Mark",
              :LandingPage => payment_method.preferred_landing_page.present? ? payment_method.preferred_landing_page : "Login",
              :cppheaderimage => payment_method.preferred_logourl.present? ? payment_method.preferred_logourl : "",
              :NoShipping => fromPaymentPage ? 1 : 0,
              :PaymentDetails => [payment_details(items)],
              :MaxAmount => {
                  :currencyID => current_order.currency,
                  :value => current_order.total + 200
              },
              :CallbackTimeout => 6
          }

      if (!fromPaymentPage)
        callback_parameters = {
            :FlatRateShippingOptions => [{
                                             :ShippingOptionIsDefault => true,
                                             :ShippingOptionAmount => {
                                                 :currencyID => current_order.currency,
                                                 :value => 0
                                             },
                                             :ShippingOptionName => "SHIPPING ERROR"
                                         }
            ],
            :CallbackURL => "http://french.qa.deco-columbus.com/testpaypal?order_id=#{current_order.id}"
            #:CallbackURL => "http://#{request.host_with_port}/#{I18n.locale}/store/paypal/callback"
        }
        paypal_parameters.merge!(callback_parameters)
      end

      pp_request = provider.build_set_express_checkout({:SetExpressCheckoutRequestDetails => paypal_parameters})
      begin
        pp_response = provider.set_express_checkout(pp_request)
        if pp_response.success?
          redirect_to provider.express_checkout_url(pp_response, :useraction => 'commit')
        else
          flash[:error] = "PayPal failed. #{pp_response.errors.map(&:long_message).join(" ")}"
          redirect_to checkout_state_path(:payment)
        end
      rescue SocketError
        flash[:error] = "Could not connect to PayPal."
        redirect_to checkout_state_path(:payment)
      end
    end

    def confirm

      fromPaymentPage = current_order.state == "payment"

      order = current_order

      pp_details_request = provider.build_get_express_checkout_details({:Token => params[:token]})
      pp_details_response = provider.get_express_checkout_details(pp_details_request)
      details_response = pp_details_response.get_express_checkout_details_response_details

      shippingFromCallback = details_response.UserSelectedOptions.ShippingCalculationMode == "Callback"


      if !fromPaymentPage

        if !shippingFromCallback
          redirect_to :action => :cancel, :notice => "There was a problem with PayPal. You have not been charged. Please try again" and return
          #redirect_to url_for(:controller => :PaypalController, :action => :cancel ) and return
        end

        order.skip_to_confirmation = true

        shippingAddress = details_response.PaymentDetails[0].ShipToAddress
        address = create_shipping_address(details_response, shippingAddress)
        address.save
        order.ship_address = address

        order.email = details_response.PayerInfo.Payer

        set_shipping_rate order, details_response.UserSelectedOptions.ShippingOptionName

        order.save!
      end


      order.payments.create!({
                                 :source => Spree::PaypalExpressCheckout.create({
                                                                                    :token => params[:token],
                                                                                    :payer_id => params[:PayerID]
                                                                                }, :without_protection => true),
                                 :amount => order.total,
                                 :payment_method => payment_method
                             }, :without_protection => true)


      order.next
      if order.complete?
        flash.notice = Spree.t(:order_processed_successfully)
        flash[:commerce_tracking] = "nothing special"
        redirect_to order_path(order, :token => order.token)
      else
        redirect_to checkout_state_path(order.state)
      end
    end

    def cancel

      notice = params[:notice] || "Don't want to use PayPal? No problems."

      flash[:notice] = notice
      if current_order.state != "payment"
        redirect_to cart_path
      else
        redirect_to checkout_state_path(current_order.state)
      end

    end

    def callback
      #Jeantine/Mark 23 Jan 14 - This will only work if all items can be sent by the same shipping method
      #Currently it is expected there will be only one shipping method.
      # If an order contains items that cannot be sent by the same shipping method paypal will still allow the user to select either shipping method
      country = Spree::Country.find_by_iso(params['SHIPTOCOUNTRY'])

      ship_address = Spree::Address.new(
          :address1 =>params['SHIPTOSTREET'],
          :address2=>params['SHIPTOSTREET2'],
          :city=>params['SHIPTOCITY'],
          :zipcode=>params['SHIPTOZIP'],
          :country=>country)
      #we are not going to save the address here as we don't have enough information to satisfy spree
      session[:order_id] = params['order_id']
      order = current_order
      order.ship_address = ship_address
      order.create_proposed_shipments

      if !order.shipments.present?
        return build_callback_response "NO_SHIPPING_OPTION_DETAILS" => 1
      end

      callback_response = {'CURRENCYCODE' => params['CURRENCYCODE']}

      shipping_rates = get_shipping_rates order
      shipping_rates.each_with_index { |shipping_rate, index| callback_response.merge!(create_shipping_rate_response shipping_rate, index) }
      callback_response['L_SHIPPINGOPTIONISDEFAULT0'] = true

      build_callback_response  callback_response
    end

    def build_callback_response(callback_response)
      formatted_response = format_nvp_response "&METHOD=CallbackResponse", callback_response
      render :text => formatted_response
    end

    def format_nvp_response method, response_hash
      response_hash.inject(method) { |string, pair| string + '&' +  pair[0].to_s + '=' + pair[1].to_s  }
    end

    def get_shipping_rates order
      order.shipments.flat_map { |shipment| shipment.shipping_rates}
    end

    def create_shipping_rate_response shipping_rate, index
      index = index.to_s
      {"L_SHIPPINGOPTIONNAME" + index => "", #Internal name. but shown in PayPal UI
       "L_SHIPPINGOPTIONLABEL" + index => shipping_rate.shipping_method.name,
       "L_SHIPPINGOPTIONAMOUNT" + index => shipping_rate.cost.to_s,
       "L_SHIPPINGOPTIONISDEFAULT" + index => false
      }
    end

    private

    def set_shipping_rate order, selectedShippingName
      shipping_rates = get_shipping_rates order
      selected_shipping = shipping_rates.select { |shipping_rate| selectedShippingName.eql? shipping_rate.shipping_method.name }.first
      order.shipment.selected_shipping_rate_id= selected_shipping.id
    end

    def create_shipping_address(details_response, shippingAddress)
      address = Spree::Address.create
      address.firstname = shippingAddress.Name.split(" ").first
      address.lastname = shippingAddress.Name.split(" ").second
      address.address1 = shippingAddress.Street1
      address.address2 = shippingAddress.Street2
      address.city = shippingAddress.CityName
      address.phone = details_response.ContactPhone
      #_address.state = shippingAddress.StateOrProvince
      address.country = Spree::Country.find_by_iso(shippingAddress.country)
      address.zipcode = shippingAddress.PostalCode
      address
    end

    def payment_method
      Spree::PaymentMethod.find(params[:payment_method_id])
    end

    def provider
      payment_method.provider
    end

    def payment_details items
      item_sum = items.sum { |i| i[:Quantity] * i[:Amount][:value] }
      if item_sum.zero?
        # Paypal does not support no items or a zero dollar ItemTotal
        # This results in the order summary being simply "Current purchase"
        {
            :OrderTotal => {
                :currencyID => current_order.currency,
                :value => current_order.total
            }
        }
      else
        {
            :OrderTotal => {
                :currencyID => current_order.currency,
                :value => current_order.total
            },
            :ItemTotal => {
                :currencyID => current_order.currency,
                :value => item_sum
            },
            :ShippingTotal => {
                :currencyID => current_order.currency,
                :value => current_order.ship_total
            },
            :TaxTotal => {
                :currencyID => current_order.currency,
                :value => current_order.tax_total
            },
            :ShipToAddress => current_order.ship_address.present? ? address_options : nil,
            :PaymentDetailsItem => items,
            :ShippingMethod => "Shipping Method Name Goes Here",
            :PaymentAction => "Sale"
        }
      end
    end

    def address_options
      {
          :Name => current_order.ship_address.try(:full_name),
          :Street1 => current_order.ship_address.address1,
          :Street2 => current_order.ship_address.address2,
          :CityName => current_order.ship_address.city,
          # :phone => current_order.bill_address.phone,
          :StateOrProvince => current_order.ship_address.state_text,
          :Country => current_order.ship_address.country.iso,
          :PostalCode => current_order.ship_address.zipcode
      }
    end
  end
end
