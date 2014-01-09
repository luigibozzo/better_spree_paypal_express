class FakePayPalProvider

  def initialize
    @pp_details_response = Hashie::Mash.new
  end

  def build_get_express_checkout_details _args
    nil
  end

  def get_express_checkout_details _args
    @pp_details_response
  end

  def set_checkout_response response
    @pp_details_response.get_express_checkout_details_response_details = response
  end




end