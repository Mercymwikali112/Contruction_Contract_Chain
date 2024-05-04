module construction_contract_chain::construction_contract_chain {

    // Imports
    use sui::transfer;
    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::clock::{Clock, timestamp_ms};
    use sui::object::{Self, UID, ID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{TxContext, sender};
    use sui::table::{Self, Table};

    use std::option::{Option, none, some, borrow};
    use std::string::{String};
    use std::vector::{Self};

    // Errors
    const ERROR_INVALID_SKILL: u64 = 0;
    const ERROR_PROJECT_CLOSED: u64 = 1;
    const ERROR_INVALID_CAP: u64 = 2;
    const ERROR_INSUFFICIENT_FUNDS: u64 = 3;
    const ERROR_WORK_NOT_SUBMITTED: u64 = 4;
    const ERROR_WRONG_ADDRESS: u64 = 5;
    const ERROR_TIME_IS_UP: u64 = 6;
    const ERROR_INCORRECT_LEASER: u64 = 7;
    const ERROR_DISPUTE_FALSE: u64 = 8;

    // Struct definitions
    
    // ConstructionJob Struct
    struct ConstructionJob has key, store {
        id: UID,
        inner: ID,
        contractor: address,
        workers: Table<address, Worker>,
        description: String,
        required_skills: vector<String>,
        project_type: String,
        budget: u64,
        payment: Balance<SUI>,
        dispute: bool,
        rating: Option<u64>,
        status: bool,
        worker: Option<address>,
        work_submitted: bool,
        created_at: u64,
        deadline: u64,
    }
    
    struct ConstructionJobCap has key {
        id: UID,
        project_id: ID
    }
    
    // Worker Struct
    struct Worker has key, store {
        id: UID,
        project_id: ID,
        contractor: address,
        description: String,
        skills: vector<String>
    }
    
    // Complaint Struct
    struct Complaint has key, store {
        id: UID,
        worker: address,
        contractor: address,
        reason: String,
        decision: bool,
    }

    struct AdminCap has key {id: UID}

    fun init(ctx: &mut TxContext) {
        transfer::transfer(AdminCap{id: object::new(ctx)}, sender(ctx));
    }

    // Accessors
    public fun get_job_description(job: &ConstructionJob): String {
        job.description
    }

    public fun get_job_budget(job: &ConstructionJob): u64 {
        job.budget
    }

    public fun get_job_status(job: &ConstructionJob): bool {
        job.status
    }

    public fun get_job_deadline(job: &ConstructionJob): u64 {
        job.deadline
    }

    // Public - Entry functions

    public fun new_worker(project: ID, description_: String, ctx: &mut TxContext) : Worker {
        let worker = Worker {
            id: object::new(ctx),
            project_id: project,
            contractor: sender(ctx),
            description: description_,
            skills: vector::empty()
        };
        worker
    }

    public entry fun bid_work(project: &mut ConstructionJob, worker: Worker, ctx: &mut TxContext) {
        assert!(!project.status, ERROR_PROJECT_CLOSED);
        assert!(check_worker_skills(&worker.skills, &project.required_skills), ERROR_INVALID_SKILL);
        table::add(&mut project.workers, sender(ctx), worker);
    }

    public fun choose_worker(cap: &ConstructionJobCap, project: &mut ConstructionJob, coin: Coin<SUI>, chosen: address, ctx: &mut TxContext) : Worker {
        assert!(cap.project_id == object::id(project), ERROR_INVALID_CAP);
        assert!(coin::value(&coin) >= project.budget, ERROR_INSUFFICIENT_FUNDS);

        let worker = table::remove(&mut project.workers, chosen);
        let payment = coin::into_balance(coin);
        balance::join(&mut project.payment, payment);
        project.status = true;
        project.worker = some(chosen);

        worker
    }

    // Create a new construction project
    public entry fun new_project(
        c: &Clock,
        description_: String,
        project_type_: String,
        budget_: u64,
        duration_: u64,
        required_skills: vector<String>,
        ctx: &mut TxContext
    ) {
        let id_ = object::new(ctx);
        let inner_ = object::uid_to_inner(&id_);
        let deadline_ = timestamp_ms(c) + duration_;

        transfer::share_object(ConstructionJob {
            id: id_,
            inner: inner_,
            contractor: sender(ctx),
            workers: table::new(ctx),
            description: description_,
            required_skills: required_skills,
            project_type: project_type_,
            budget: budget_,
            payment: balance::zero(),
            dispute: false,
            rating: none(),
            status: false,
            worker: none(),
            work_submitted: false,
            created_at: timestamp_ms(c),
            deadline: deadline_
        });

        transfer::transfer(ConstructionJobCap{id: object::new(ctx), project_id: inner_}, sender(ctx));
    }
    
    public fun new_worker(project: ID, description_: String, ctx: &mut TxContext) : Worker {
        let worker = Worker {
            id: object::new(ctx),
            project_id: project,
            contractor: sender(ctx),
            description: description_,
            skills: vector::empty()
        };
        worker
    }

    public fun add_skill(worker: &mut Worker, skill: String) {
        assert!(!vector::contains(&worker.skills, &skill), ERROR_INVALID_SKILL);
        vector::push_back(&mut worker.skills, skill);
    }

    public fun bid_work(project: &mut ConstructionJob, worker: Worker, ctx: &mut TxContext) {
        assert!(!project.status, ERROR_PROJECT_CLOSED);
        table::add(&mut project.workers, sender(ctx), worker);
    }

    public entry fun submit_work(project: &mut ConstructionJob, c: &Clock, ctx: &mut TxContext) {
        assert!(timestamp_ms(c) < project.deadline, ERROR_TIME_IS_UP);
        assert!(*borrow(&project.worker) == sender(ctx), ERROR_WRONG_ADDRESS);
        project.work_submitted = true;
    }

    public entry fun confirm_work(cap: &ConstructionJobCap, project: &mut ConstructionJob, ctx: &mut TxContext) {
        assert!(cap.project_id == object::id(project), ERROR_INVALID_CAP);
        assert!(project.work_submitted, ERROR_WORK_NOT_SUBMITTED);

        let payment = balance::withdraw_all(&mut project.payment);
        let coin = coin::from_balance(payment, ctx);

        transfer::public_transfer(coin, *borrow(&project.worker));
    }


    // Additional functions for handling complaints and dispute resolutions
    public fun file_complaint(project: &mut ConstructionJob, c:&Clock, reason: String, ctx: &mut TxContext) {
        assert!(timestamp_ms(c) > project.deadline, ERROR_TIME_IS_UP); // Ensure that the complaint is filed after the project deadline
        
        let complainer = sender(ctx);
        let contractor = project.contractor;
        
        // Ensure that the complaint is filed by either the worker or the contractor
         assert!(complainer == sender(ctx) || contractor == sender(ctx), ERROR_INCORRECT_LEASER);

        // Create the complaint
        let complaint = Complaint{
            id: object::new(ctx),
            worker: complainer,
            contractor: contractor,
            reason: reason,
            decision: false,
        };

        // Mark the project as disputed
        project.dispute = true;

        transfer::share_object(complaint);
    }

    // Admin or arbitrator decides the outcome of a dispute
    public fun resolve_dispute(_: &AdminCap, project: &mut ConstructionJob, complaint: &mut Complaint, decision: bool, ctx: &mut TxContext) {
        assert!(project.dispute, ERROR_DISPUTE_FALSE); // Ensure there is an active dispute
        
        // Decision process
        if (decision) {
            // If decision is true, transfer the escrow to the worker
            let payment = balance::withdraw_all(&mut project.payment);
            let coin = coin::from_balance(payment, ctx);
            transfer::public_transfer(coin, complaint.worker);
        } else {
            // If decision is false, return the escrow to the contractor
            let payment = balance::withdraw_all(&mut project.payment);
            let coin = coin::from_balance(payment, ctx);
            transfer::public_transfer(coin, project.contractor);
            
            // Close the dispute
            project.dispute = false;
            complaint.decision = decision;
        }
    }

    // Helper function to add skills to a worker
    public fun add_skill(worker: &mut Worker, skill: String) {
        assert!(!vector::contains(&worker.skills, &skill), ERROR_INVALID_SKILL);
        vector::push_back(&mut worker.skills, skill);
    }

    // Check if a worker has the required skills
    public fun check_worker_skills(worker_skills: &vector<String>, required_skills: &vector<String>): bool {
        let has_skills = true;
        let i = 0;
        while (i < vector::length(required_skills)) {
            let skill = vector::borrow(required_skills, i);
            if (!vector::contains(worker_skills, skill)) {
                has_skills = false;
                break;
            };
            i = i + 1;
        };
        has_skills
    }

    // Rate a worker after project completion
    public entry fun rate_worker(project: &mut ConstructionJob, rating: u64, ctx: &mut TxContext) {
        assert!(project.contractor == sender(ctx), ERROR_WRONG_ADDRESS);
        assert!(project.work_submitted && !project.dispute, ERROR_WORK_NOT_SUBMITTED);
        project.rating = some(rating);
    }

    // Get the rating of a worker
    public fun get_worker_rating(project: &ConstructionJob): Option<u64> {
        project.rating
    }
}

