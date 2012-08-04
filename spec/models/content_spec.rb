require 'spec_helper'

describe Content do
  before :each do
    @text =
"""
hi @tom, I have a question from @pi314 about the following code:
```
class A
  def set_some_variable
    @some_variable = 1
  end
end
```
and also the following code
    class A
      def get_some_variable
        @some_variable
      end
    end
what is the 'at' symbol doing there? @dementrock
"""
    User.delete_all
    User.create!(external_id: "1", username: "tom", email: "tom@test.com")
    User.create!(external_id: "2", username: "pi314", email: "pi314@test.com")
  end

  describe "#get_marked_text(text)" do
    it "returns marked at text" do
      converted = Content.get_marked_text(@text)
      converted.should include "@tom_0"
      converted.should include "@pi314_1"
      converted.should include "@some_variable_2"
      converted.should include "@some_variable_3"
      converted.should include "@dementrock_4"
    end
  end

  describe "#get_valid_at_position_list(text)" do
    it "returns the list of positions for the valid @ notifications, filtering out the ones in code blocks" do
      list = Content.get_valid_at_position_list(@text)
      list.should include [0, "tom", "1"]
      list.should include [1, "pi314", "2"]
      list.length.should == 2
    end
  end
end