require 'logger'
require_relative 'concerns/searchable'
require_relative 'content'
require_relative 'constants'
require_relative 'edit_history'

logger = Logger.new(STDOUT)
logger.level = Logger::WARN

class Comment < Content
  include Mongoid::Tree
  include Mongoid::Timestamps
  include Mongoid::MagicCounterCache
  include ActiveModel::MassAssignmentSecurity
  include Elasticsearch::Model
  include Searchable

  voteable self, :up => +1, :down => -1

  field :course_id, type: String
  field :body, type: String
  field :endorsed, type: Boolean, default: false
  field :endorsement, type: Hash
  field :anonymous, type: Boolean, default: false
  field :anonymous_to_peers, type: Boolean, default: false
  field :commentable_id, type: String
  field :at_position_list, type: Array, default: []
  field :sk, type: String, default: nil
  field :child_count, type: Integer
  field :retired_username, type: String, default: nil

  index({author_id: 1, course_id: 1})
  index({_type: 1, comment_thread_id: 1, author_id: 1, updated_at: 1})
  index({comment_thread_id: 1, author_id: 1, created_at: 1})

  index_name = "comment"

  mapping dynamic: 'false' do
    indexes :body, type: :text, store: true, term_vector: :with_positions_offsets
    indexes :course_id, type: :keyword
    indexes :comment_thread_id, type: :keyword
    indexes :commentable_id, type: :keyword
    indexes :group_id, type: :keyword
    indexes :context, type: :keyword
    indexes :created_at, type: :date
    indexes :updated_at, type: :date
    # NOTE: this field needs only for testing
    indexes :title, type: :keyword
  end

  def as_indexed_json(options={})
    as_json(except: [:id, :_id])
  end

  belongs_to :comment_thread, index: true
  belongs_to :author, class_name: 'User', inverse_of: :comments, index: true
  embeds_many :edit_history, cascade_callbacks: true

  attr_accessible :body, :course_id, :anonymous, :anonymous_to_peers, :endorsed, :endorsement, :retired_username

  validates_presence_of :comment_thread, autosave: false
  validates_presence_of :body
  validates_presence_of :course_id
  validates_presence_of :author, autosave: false

  counter_cache :comment_thread

  before_destroy :destroy_children
  before_create :set_thread_last_activity_at
  before_save :set_sk
  before_save do
    unless anonymous or anonymous_to_peers or not body_changed?
      author.update_activity_timestamp course_id
    end
  end
  after_destroy do
    unless anonymous or anonymous_to_peers
      if parent_id.nil?
        author.update_stats_for_course(course_id, responses: -1)
      else
        author.update_stats_for_course(course_id, replies: -1)
      end
    end
  end
  after_create do
    # Don't count anonymous posts
    unless anonymous or anonymous_to_peers
      if parent_id.nil?
        author.update_stats_for_course(course_id, responses: 1)
      else
        author.update_stats_for_course(course_id, replies: 1)
      end
    end
  end

  def self.hash_tree(nodes)
    nodes.map { |node, sub_nodes| node.to_hash.merge('children' => hash_tree(sub_nodes).compact) }
  end

  # This should really go somewhere else, but sticking it here for now. This is
  # used to flatten out the subtree fetched by calling self.subtree. This is
  # equivalent to calling descendants_and_self; however, calling
  # descendants_and_self and subtree both is very inefficient. It's cheaper to
  # just flatten out the subtree, and simpler than duplicating the code that
  # actually creates the subtree.
  def self.flatten_subtree(x)
    if x.is_a? Array
      x.flatten.map { |y| self.flatten_subtree(y) }
    elsif x.is_a? Hash
      x.to_a.map { |y| self.flatten_subtree(y) }.flatten
    else
      x
    end
  end

  def to_hash(params={})
    sort_by_parent_and_time = Proc.new do |x, y|
      arr_cmp = x.parent_ids.map(&:to_s) <=> y.parent_ids.map(&:to_s)
      if arr_cmp != 0
        arr_cmp
      else
        x.created_at <=> y.created_at
      end
    end
    if params[:recursive]
      # TODO: remove and reuse the new hierarchical sort keys if possible
      subtree_hash = subtree(sort: sort_by_parent_and_time)
      self.class.hash_tree(subtree_hash).first
    else
      as_document
        .slice(BODY, COURSE_ID, ENDORSED, ENDORSEMENT, ANONYMOUS, ANONYMOUS_TO_PEERS, CREATED_AT, UPDATED_AT, AT_POSITION_LIST)
        .merge!("id" => _id,
                "user_id" => author_id,
                "username" => author_username,
                "depth" => depth,
                "closed" => comment_thread.nil? ? false : comment_thread.closed,
                "edit_history" => edit_history.map(&:to_hash),
                "thread_id" => comment_thread_id,
                "parent_id" => parent_ids[-1],
                "commentable_id" => comment_thread.nil? ? nil : comment_thread.commentable_id,
                "votes" => votes.slice(COUNT, UP_COUNT, DOWN_COUNT, POINT),
                "abuse_flaggers" => abuse_flaggers,
                "type" => COMMENT,
                "child_count" => get_cached_child_count)
    end
  end

  def get_cached_child_count
    update_cached_child_count if self.child_count.nil?
    self.child_count
  end

  def update_cached_child_count
    child_comments_count = Comment.where({"parent_id" => self._id}).count()
    self.set(child_count: child_comments_count)
  end

  def commentable_id
    return nil unless self.comment_thread
    self.comment_thread.commentable_id
  rescue Mongoid::Errors::DocumentNotFound
    nil
  end

  def group_id
    return nil unless self.comment_thread
    self.comment_thread.group_id
  rescue Mongoid::Errors::DocumentNotFound
    nil
  end

  def context
    return nil unless self.comment_thread
    self.comment_thread.context
  rescue Mongoid::Errors::DocumentNotFound
    nil
  end

  def course_context?
    self.context == 'course'
  end

  def standalone_context?
    self.context == 'standalone'
  end

  def self.by_date_range_and_thread_ids from_when, to_when, thread_ids
    #return all content between from_when and to_when

    self.where(:created_at.gte => (from_when)).where(:created_at.lte => (to_when)).
        where(:comment_thread_id.in => thread_ids)
  end

  private

  def set_thread_last_activity_at
    self.comment_thread.update_attribute(:last_activity_at, Time.now.utc)
  end

  def set_sk
    # this attribute is explicitly write-once
    if self.sk.nil?
      self.sk = (self.parent_ids.dup << self.id).join("-")
    end
  end

  begin
    require 'new_relic/agent/method_tracer'
    include ::NewRelic::Agent::MethodTracer
    add_method_tracer :to_hash
  rescue LoadError
    logger.warn "NewRelic agent library not installed"
  end
end
