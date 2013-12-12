Spree::Gateway.class_eval do
  def can_be_displayed_on_cart_page
    false
  end
end